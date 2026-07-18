import Foundation

struct RosterLegAnalysis: Equatable, Sendable, Identifiable {
    let legID: String
    let blockMinutes: Int?

    var id: String {
        legID
    }
}

enum RosterIntervalAnalysis: Equatable, Sendable {
    case notApplicable
    case firstFlight
    case measured(minutes: Int)
    case overlap(minutes: Int)
    case interruptedByActivity
    case unresolvedChocks
}

enum RosterRestLocation: Equatable, Sendable {
    case base
    case away
}

enum RosterRestCompliance: Equatable, Sendable {
    case compliant(marginMinutes: Int)
    case shortfall(minutes: Int)
    case needsReview
}

struct RosterRestAssessment: Equatable, Sendable, Identifiable {
    let previousDutyID: String
    let currentDutyID: String
    let previousPeriodIndex: Int
    let currentPeriodIndex: Int
    let stationIATA: String
    let location: RosterRestLocation
    let availableChocksMinutes: Int
    let minimumRestMinutes: Int
    let transitionMinutes: Int?
    let requiredChocksMinutes: Int?
    let compliance: RosterRestCompliance
    let reviewReasons: [String]

    var id: String {
        "\(previousDutyID)|\(previousPeriodIndex)|\(currentDutyID)|\(currentPeriodIndex)"
    }

    func applyingMinimumRestOverride(_ minimumRestMinutes: Int)
        -> RosterRestAssessment
    {
        let boundedMinimum = min(max(minimumRestMinutes, 1), 2_880)
        let hardFloor = reviewReasons.contains("Confirm the two required local nights")
            ? 36 * 60
            : 0
        let required = transitionMinutes.map {
            max(hardFloor, boundedMinimum + $0)
        }
        let adjustedCompliance: RosterRestCompliance
        if let required, availableChocksMinutes < required {
            adjustedCompliance = .shortfall(
                minutes: required - availableChocksMinutes
            )
        } else if let required {
            adjustedCompliance = .compliant(
                marginMinutes: availableChocksMinutes - required
            )
        } else {
            adjustedCompliance = .needsReview
        }
        return RosterRestAssessment(
            previousDutyID: previousDutyID,
            currentDutyID: currentDutyID,
            previousPeriodIndex: previousPeriodIndex,
            currentPeriodIndex: currentPeriodIndex,
            stationIATA: stationIATA,
            location: location,
            availableChocksMinutes: availableChocksMinutes,
            minimumRestMinutes: boundedMinimum,
            transitionMinutes: transitionMinutes,
            requiredChocksMinutes: required,
            compliance: adjustedCompliance,
            reviewReasons: reviewReasons
        )
    }
}

struct RosterFlightPeriodAnalysis: Equatable, Sendable, Identifiable {
    let index: Int
    let legIDs: [String]
    let resolvedBlockMinutes: Int
    let unresolvedLegCount: Int
    let flyingWindowMinutes: Int?
    let groundToNextPeriodMinutes: Int?

    var id: Int {
        index
    }
}

struct RosterDutyAnalysis: Equatable, Sendable, Identifiable {
    let dutyID: String
    let rosterSpanMinutes: Int
    let intervalBefore: RosterIntervalAnalysis
    let legs: [RosterLegAnalysis]
    let flightPeriods: [RosterFlightPeriodAnalysis]
    let restAssessments: [RosterRestAssessment]

    var id: String {
        dutyID
    }

    var resolvedBlockMinutes: Int {
        flightPeriods.reduce(0) { $0 + $1.resolvedBlockMinutes }
    }

    var unresolvedLegCount: Int {
        flightPeriods.reduce(0) { $0 + $1.unresolvedLegCount }
    }

    func analysis(for legID: String) -> RosterLegAnalysis? {
        legs.first { $0.legID == legID }
    }
}

struct RosterPeriodSummary: Equatable, Sendable {
    let flightRotationCount: Int
    let flightPeriodCount: Int
    let legCount: Int
    let resolvedBlockMinutes: Int
    let unresolvedLegCount: Int
    let measuredIntervalCount: Int
    let shortestMeasuredIntervalMinutes: Int?
    let overlapCount: Int
    let activityReviewIntervalCount: Int
}

struct RosterLegVerification: Equatable, Sendable, Identifiable {
    let dutyID: String
    let legID: String
    let flightNumber: String
    let originIATA: String
    let destinationIATA: String
    let departure: RosterLocalDateTime
    let arrival: RosterLocalDateTime
    let unresolvedStationIATAs: [String]

    var id: String {
        "\(dutyID)|\(legID)"
    }
}

struct RosterOverlapConflict: Equatable, Sendable, Identifiable {
    let previousDutyID: String
    let currentDutyID: String
    let minutes: Int

    var id: String {
        "\(previousDutyID)|\(currentDutyID)"
    }
}

struct RosterAnalysisAttention: Equatable, Sendable {
    let legVerifications: [RosterLegVerification]
    let overlapConflicts: [RosterOverlapConflict]

    var isEmpty: Bool {
        legVerifications.isEmpty && overlapConflicts.isEmpty
    }
}

struct RosterPeriodAnalyzer {
    static func summarize(_ duties: [RosterDuty]) -> RosterPeriodSummary {
        let analyses = RosterDutyAnalyzer.analyze(duties)
        let measuredIntervals = analyses.compactMap { analysis -> Int? in
            guard case .measured(let minutes) = analysis.intervalBefore else {
                return nil
            }
            return minutes
        }
        return RosterPeriodSummary(
            flightRotationCount: duties.filter { $0.kind == .flight }.count,
            flightPeriodCount: analyses.flatMap(\.flightPeriods).count,
            legCount: duties.reduce(0) { $0 + $1.legs.count },
            resolvedBlockMinutes: analyses.reduce(0) {
                $0 + $1.resolvedBlockMinutes
            },
            unresolvedLegCount: analyses.reduce(0) {
                $0 + $1.unresolvedLegCount
            },
            measuredIntervalCount: measuredIntervals.count,
            shortestMeasuredIntervalMinutes: measuredIntervals.min(),
            overlapCount: analyses.filter { analysis in
                if case .overlap = analysis.intervalBefore {
                    return true
                }
                return false
            }.count,
            activityReviewIntervalCount: analyses.filter {
                $0.intervalBefore == .interruptedByActivity
            }.count
        )
    }

    static func attention(
        duties: [RosterDuty],
        issues: [RosterImportIssue]
    ) -> RosterAnalysisAttention {
        let orderedDuties = duties.sorted {
            $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start
        }
        let analyses = Dictionary(
            uniqueKeysWithValues: RosterDutyAnalyzer.analyze(orderedDuties)
                .map { ($0.dutyID, $0) }
        )

        let legVerifications = orderedDuties.flatMap { duty in
            guard let analysis = analyses[duty.id] else {
                return [RosterLegVerification]()
            }
            return duty.legs.compactMap { leg in
                guard analysis.analysis(for: leg.id)?.blockMinutes == nil else {
                    return nil
                }

                var stations = Set(
                    issues.lazy.filter {
                        $0.dutyID == duty.id
                        && $0.flightNumber == leg.flightNumber
                    }.map(\.stationIATA)
                )
                if leg.departure.instant == nil {
                    stations.insert(leg.originIATA)
                }
                if leg.arrival.instant == nil {
                    stations.insert(leg.destinationIATA)
                }

                return RosterLegVerification(
                    dutyID: duty.id,
                    legID: leg.id,
                    flightNumber: leg.flightNumber,
                    originIATA: leg.originIATA,
                    destinationIATA: leg.destinationIATA,
                    departure: leg.departure,
                    arrival: leg.arrival,
                    unresolvedStationIATAs: stations.sorted()
                )
            }
        }

        let flightDuties = orderedDuties.filter { $0.kind == .flight }
        let overlapConflicts = flightDuties.indices.dropFirst().compactMap {
            index -> RosterOverlapConflict? in
            let previous = flightDuties[index - 1]
            let current = flightDuties[index]
            let overlap = previous.end.timeIntervalSince(current.start)
            guard overlap > 0 else {
                return nil
            }
            return RosterOverlapConflict(
                previousDutyID: previous.id,
                currentDutyID: current.id,
                minutes: Int(overlap / 60)
            )
        }

        return RosterAnalysisAttention(
            legVerifications: legVerifications,
            overlapConflicts: overlapConflicts
        )
    }
}

struct RosterDutyAnalyzer {
    private static let knownNonOperationalActivities: Set<String> = [
        "DFD",
        "DOE"
    ]

    static func analyze(
        _ duties: [RosterDuty],
        stations: [Station] = [],
        baseIATA: String? = nil
    ) -> [RosterDutyAnalysis] {
        let sorted = duties.sorted {
            $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start
        }
        let restAssessments = assessRests(
            in: sorted,
            stations: stations,
            baseIATA: baseIATA
        )
        let restsByDuty = Dictionary(
            grouping: restAssessments,
            by: \.currentDutyID
        )
        var previousFlight: RosterDuty?
        var interveningActivityNeedsReview = false
        var results: [RosterDutyAnalysis] = []

        for duty in sorted {
            let intervalBefore: RosterIntervalAnalysis
            switch duty.kind {
            case .activity:
                intervalBefore = .notApplicable
                if previousFlight != nil,
                   !knownNonOperationalActivities.contains(
                    duty.activityCode.uppercased()
                   ) {
                    interveningActivityNeedsReview = true
                }
            case .flight:
                if let previousFlight {
                    if interveningActivityNeedsReview {
                        intervalBefore = .interruptedByActivity
                    } else {
                        intervalBefore = chocksInterval(
                            after: previousFlight,
                            before: duty
                        )
                    }
                } else {
                    intervalBefore = .firstFlight
                }
                previousFlight = duty
                interveningActivityNeedsReview = false
            }

            let legs = duty.legs.map { leg in
                RosterLegAnalysis(
                    legID: leg.id,
                    blockMinutes: blockMinutes(for: leg)
                )
            }
            results.append(
                RosterDutyAnalysis(
                    dutyID: duty.id,
                    rosterSpanMinutes: wholeMinutes(
                        duty.end.timeIntervalSince(duty.start)
                    ),
                    intervalBefore: intervalBefore,
                    legs: legs,
                    flightPeriods: flightPeriods(for: duty),
                    restAssessments: restsByDuty[duty.id] ?? []
                )
            )
        }

        return results
    }

    static func isOvernightBreak(
        after period: RosterFlightPeriodAnalysis,
        in duty: RosterDuty
    ) -> Bool {
        guard let boundary = hotelBoundaryIndex(in: duty),
              duty.legs.indices.contains(boundary),
              period.legIDs.last == duty.legs[boundary].id else {
            return false
        }
        return true
    }

    private static func flightPeriods(
        for duty: RosterDuty
    ) -> [RosterFlightPeriodAnalysis] {
        guard !duty.legs.isEmpty else {
            return []
        }

        let groups: [[RosterLeg]]
        if let boundary = hotelBoundaryIndex(in: duty) {
            groups = [
                Array(duty.legs[...boundary]),
                Array(duty.legs[(boundary + 1)...])
            ]
        } else {
            groups = [duty.legs]
        }

        return groups.enumerated().map { offset, group in
            let blockValues = group.map(blockMinutes)
            let nextGroup = groups.indices.contains(offset + 1)
                ? groups[offset + 1]
                : nil
            return RosterFlightPeriodAnalysis(
                index: offset + 1,
                legIDs: group.map(\.id),
                resolvedBlockMinutes: blockValues.compactMap { $0 }.reduce(0, +),
                unresolvedLegCount: blockValues.filter { $0 == nil }.count,
                flyingWindowMinutes: flyingWindowMinutes(for: group),
                groundToNextPeriodMinutes: groundInterval(
                    after: group,
                    before: nextGroup
                )
            )
        }
    }

    private static func hotelBoundaryIndex(in duty: RosterDuty) -> Int? {
        guard let hotelCode = duty.hotelCode?.uppercased(),
              duty.legs.count > 1 else {
            return nil
        }
        let station = String(hotelCode.prefix(3))
        guard station.utf8.count == 3 else {
            return nil
        }

        return duty.legs.indices.dropLast().last { index in
            duty.legs[index].destinationIATA == station
            && duty.legs[index + 1].originIATA == station
        }
    }

    private static func blockMinutes(for leg: RosterLeg) -> Int? {
        leg.blockMinutes
    }

    private static func flyingWindowMinutes(
        for legs: [RosterLeg]
    ) -> Int? {
        guard let departure = legs.first?.departure.instant,
              let arrival = legs.last?.arrival.instant,
              arrival > departure else {
            return nil
        }
        return wholeMinutes(arrival.timeIntervalSince(departure))
    }

    private static func groundInterval(
        after legs: [RosterLeg],
        before nextLegs: [RosterLeg]?
    ) -> Int? {
        guard let arrival = legs.last?.arrival.instant,
              let departure = nextLegs?.first?.departure.instant,
              departure > arrival else {
            return nil
        }
        return wholeMinutes(departure.timeIntervalSince(arrival))
    }

    private static func wholeMinutes(_ interval: TimeInterval) -> Int {
        max(0, Int(interval / 60))
    }

    private struct RestPeriod {
        let duty: RosterDuty
        let index: Int
        let legs: [RosterLeg]
        let serviceStart: Date
        let serviceEnd: Date
    }

    private static func chocksInterval(
        after previous: RosterDuty,
        before current: RosterDuty
    ) -> RosterIntervalAnalysis {
        guard let arrival = previous.legs.last?.arrival.instant,
              let departure = current.legs.first?.departure.instant else {
            return .unresolvedChocks
        }
        let interval = departure.timeIntervalSince(arrival)
        return interval >= 0
            ? .measured(minutes: wholeMinutes(interval))
            : .overlap(minutes: wholeMinutes(-interval))
    }

    private static func assessRests(
        in duties: [RosterDuty],
        stations: [Station],
        baseIATA: String?
    ) -> [RosterRestAssessment] {
        guard !stations.isEmpty,
              let normalizedBase = baseIATA?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased(),
              normalizedBase.utf8.count == 3 else {
            return []
        }
        let stationsByIATA = Dictionary(
            uniqueKeysWithValues: stations.map { ($0.iata.uppercased(), $0) }
        )
        let periods = duties.flatMap(restPeriods)
        guard periods.count > 1 else { return [] }

        return periods.indices.dropFirst().compactMap { index in
            restAssessment(
                previous: periods[index - 1],
                current: periods[index],
                duties: duties,
                stationsByIATA: stationsByIATA,
                baseIATA: normalizedBase
            )
        }
    }

    private static func restPeriods(for duty: RosterDuty) -> [RestPeriod] {
        guard duty.kind == .flight, !duty.legs.isEmpty else { return [] }
        let groups: [[RosterLeg]]
        if let boundary = hotelBoundaryIndex(in: duty) {
            groups = [
                Array(duty.legs[...boundary]),
                Array(duty.legs[(boundary + 1)...])
            ]
        } else {
            groups = [duty.legs]
        }

        return groups.enumerated().compactMap { offset, legs in
            guard let firstDeparture = legs.first?.departure.instant,
                  let lastArrival = legs.last?.arrival.instant else {
                return nil
            }
            let serviceStart = offset == 0
                ? duty.start
                : firstDeparture.addingTimeInterval(-60 * 60)
            let serviceEnd = offset == groups.count - 1
                ? duty.end
                : lastArrival.addingTimeInterval(30 * 60)
            guard serviceEnd > serviceStart else { return nil }
            return RestPeriod(
                duty: duty,
                index: offset + 1,
                legs: legs,
                serviceStart: serviceStart,
                serviceEnd: serviceEnd
            )
        }
    }

    private static func restAssessment(
        previous: RestPeriod,
        current: RestPeriod,
        duties: [RosterDuty],
        stationsByIATA: [String: Station],
        baseIATA: String
    ) -> RosterRestAssessment? {
        guard let previousArrival = previous.legs.last?.arrival.instant,
              let currentDeparture = current.legs.first?.departure.instant,
              let stationIATA = previous.legs.last?.destinationIATA,
              current.legs.first?.originIATA == stationIATA else {
            return nil
        }

        let available = max(
            0,
            Int(currentDeparture.timeIntervalSince(previousArrival) / 60)
        )
        let location: RosterRestLocation = stationIATA == baseIATA
            ? .base
            : .away
        let serviceMinutes = wholeMinutes(
            previous.serviceEnd.timeIntervalSince(previous.serviceStart)
        )
        var minimumRest = max(
            location == .base ? 13 * 60 : 11 * 60,
            serviceMinutes
        )
        var reasons: [String] = []

        if overlapsLisbonCircadian(
            from: previous.serviceStart,
            to: previous.serviceEnd
        ) {
            minimumRest += 2 * 60
        }

        let offsetDifference = timeZoneDifferenceHours(
            for: previous,
            stationsByIATA: stationsByIATA
        )
        if location == .away, let offsetDifference, offsetDifference >= 3 {
            minimumRest = max(
                minimumRest,
                14 * 60 + max(1, offsetDifference - 2) * 30
            )
            if offsetDifference > 6 {
                minimumRest = max(minimumRest, 24 * 60)
                reasons.append("Confirm the required local night")
            }
        }

        let transition: Int?
        switch location {
        case .base:
            transition = 4 * 60
        case .away:
            if let station = stationsByIATA[stationIATA],
               let transport = TimeCalculator.defaultTransportMinutes(
                departure: currentDeparture,
                station: station,
                stationHolidays: station.holidays ?? []
               ) {
                transition = 3 * 60 + 2 * transport.maximum
                if !transport.isExact || !station.alternatives.isEmpty {
                    reasons.append("Confirm the applicable transfer option")
                }
            } else {
                transition = nil
                reasons.append("Transition time is unavailable")
            }
        }

        var required = transition.map { minimumRest + $0 }
        if location == .away,
           let offsetDifference,
           offsetDifference >= 8 {
            required = max(required ?? 0, 36 * 60)
            reasons.append("Confirm the two required local nights")
        }
        if location == .base,
           previous.legs.contains(where: { ($0.blockMinutes ?? 0) >= 9 * 60 + 30 }) {
            reasons.append("Confirm whether additional rest (RAD) applies")
        }
        if previous.duty.id != current.duty.id,
           hasUnknownInterveningActivity(
            after: previous.duty,
            before: current.duty,
            in: duties
           ) {
            reasons.append("An intervening activity needs review")
        }

        let compliance: RosterRestCompliance
        if let required, available < required {
            compliance = .shortfall(minutes: required - available)
        } else if let required, reasons.isEmpty {
            compliance = .compliant(marginMinutes: available - required)
        } else {
            compliance = .needsReview
        }

        return RosterRestAssessment(
            previousDutyID: previous.duty.id,
            currentDutyID: current.duty.id,
            previousPeriodIndex: previous.index,
            currentPeriodIndex: current.index,
            stationIATA: stationIATA,
            location: location,
            availableChocksMinutes: available,
            minimumRestMinutes: minimumRest,
            transitionMinutes: transition,
            requiredChocksMinutes: required,
            compliance: compliance,
            reviewReasons: reasons
        )
    }

    private static func hasUnknownInterveningActivity(
        after previous: RosterDuty,
        before current: RosterDuty,
        in duties: [RosterDuty]
    ) -> Bool {
        duties.contains { duty in
            duty.kind == .activity
            && duty.start >= previous.end
            && duty.end <= current.start
            && !knownNonOperationalActivities.contains(
                duty.activityCode.uppercased()
            )
        }
    }

    private static func timeZoneDifferenceHours(
        for period: RestPeriod,
        stationsByIATA: [String: Station]
    ) -> Int? {
        guard let first = period.legs.first,
              let last = period.legs.last,
              let startZone = stationsByIATA[first.originIATA]
                .flatMap({ TimeZone(identifier: $0.timeZone) }),
              let endZone = stationsByIATA[last.destinationIATA]
                .flatMap({ TimeZone(identifier: $0.timeZone) }) else {
            return nil
        }
        let difference = abs(
            endZone.secondsFromGMT(for: period.serviceEnd)
                - startZone.secondsFromGMT(for: period.serviceStart)
        )
        return difference / 3_600
    }

    private static func overlapsLisbonCircadian(
        from start: Date,
        to end: Date
    ) -> Bool {
        guard end > start,
              let lisbon = TimeZone(identifier: "Europe/Lisbon") else {
            return false
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = lisbon
        var day = calendar.startOfDay(for: start)
        let finalDay = calendar.startOfDay(for: end)
        while day <= finalDay {
            guard let windowStart = calendar.date(
                bySettingHour: 2,
                minute: 0,
                second: 0,
                of: day
            ),
            let windowEnd = calendar.date(
                bySettingHour: 6,
                minute: 0,
                second: 0,
                of: day
            ) else { return false }
            if start < windowEnd && end > windowStart {
                return true
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day)
            else { return false }
            day = next
        }
        return false
    }
}
