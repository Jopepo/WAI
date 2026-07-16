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
}

struct RosterDutyAnalyzer {
    private static let knownNonOperationalActivities: Set<String> = [
        "DFD",
        "DOE"
    ]

    static func analyze(_ duties: [RosterDuty]) -> [RosterDutyAnalysis] {
        let sorted = duties.sorted {
            $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start
        }
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
                        let interval = duty.start.timeIntervalSince(
                            previousFlight.end
                        )
                        intervalBefore = interval >= 0
                            ? .measured(minutes: wholeMinutes(interval))
                            : .overlap(minutes: wholeMinutes(-interval))
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
                    flightPeriods: flightPeriods(for: duty)
                )
            )
        }

        return results
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
        guard let departure = leg.departure.instant,
              let arrival = leg.arrival.instant,
              arrival > departure else {
            return nil
        }
        return wholeMinutes(arrival.timeIntervalSince(departure))
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
}
