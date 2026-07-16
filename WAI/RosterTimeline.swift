import Foundation

enum RosterStayTimingStatus: Equatable, Sendable {
    case calculated(TimeCalculationDetails)
    case arrivalMissing
    case nextDepartureMissing
    case sequenceMismatch(nextOriginIATA: String)
    case stationDataMissing
    case departureTimeUnresolved
    case calculationUnavailable
}

enum RosterReportTimeSource: Equatable, Sendable {
    case roster
    case standardBeforeDeparture
}

struct RosterStay: Equatable, Sendable, Identifiable {
    let id: String
    let arrivalDutyID: String
    let hotelCode: String
    let stationIATA: String
    let stationTimeZoneIdentifier: String?
    let hotelName: String?
    let hotelCity: String?
    let hotelCountry: String?
    let arrivalLeg: RosterLeg?
    let departureDutyID: String?
    let departureLeg: RosterLeg?
    let timingStatus: RosterStayTimingStatus
    let reportTimeSource: RosterReportTimeSource?
    let automaticallySelectedAlternative: String?
    let requiresTransportConfirmation: Bool
    let availableTransportAlternatives: [String]
}

struct RosterTimelineBuilder {
    private static let defaultAlternativeTag = "__WAI3_DEFAULT__"

    static func stays(
        duties: [RosterDuty],
        stations: [Station],
        hotels: [Hotel]
    ) -> [RosterStay] {
        let sortedDuties = duties.sorted {
            $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start
        }
        let contexts = sortedDuties.flatMap { duty in
            duty.legs.map { LegContext(duty: duty, leg: $0) }
        }
        let stationsByIATA = Dictionary(
            uniqueKeysWithValues: stations.map { ($0.iata.uppercased(), $0) }
        )
        let hotelsByIATA = Dictionary(
            uniqueKeysWithValues: hotels.map { ($0.iata.uppercased(), $0) }
        )

        return sortedDuties.compactMap { duty in
            guard let rawHotelCode = duty.hotelCode else {
                return nil
            }
            let hotelCode = rawHotelCode.uppercased()
            let stationIATA = stayStationIATA(
                hotelCode: hotelCode,
                duty: duty
            )
            let hotel = hotelsByIATA[stationIATA]
            let station = stationsByIATA[stationIATA]
            let arrivalContext = contexts.last { context in
                context.duty.id == duty.id
                && context.leg.destinationIATA == stationIATA
            }
            let arrivalLeg = arrivalContext?.leg
            let stayID = [
                duty.id,
                hotelCode,
                arrivalLeg?.id ?? "arrival-missing"
            ].joined(separator: "|")

            guard let arrivalContext,
                  let arrivalIndex = contexts.firstIndex(where: {
                    $0.duty.id == arrivalContext.duty.id
                    && $0.leg.id == arrivalContext.leg.id
                  }) else {
                return stay(
                    id: stayID,
                    duty: duty,
                    hotelCode: hotelCode,
                    stationIATA: stationIATA,
                    hotel: hotel,
                    arrivalLeg: arrivalLeg,
                    departureContext: nil,
                    timingStatus: .arrivalMissing,
                    reportTimeSource: nil,
                    selectedAlternative: nil,
                    requiresConfirmation: station?.alternatives.isEmpty == false,
                    alternatives: station?.alternatives.map(\.label) ?? []
                )
            }

            let nextContext = contexts.indices.contains(arrivalIndex + 1)
                ? contexts[arrivalIndex + 1]
                : nil
            guard let nextContext else {
                return stay(
                    id: stayID,
                    duty: duty,
                    hotelCode: hotelCode,
                    stationIATA: stationIATA,
                    hotel: hotel,
                    arrivalLeg: arrivalLeg,
                    departureContext: nil,
                    timingStatus: .nextDepartureMissing,
                    reportTimeSource: nil,
                    selectedAlternative: nil,
                    requiresConfirmation: station?.alternatives.isEmpty == false,
                    alternatives: station?.alternatives.map(\.label) ?? []
                )
            }
            guard nextContext.leg.originIATA == stationIATA else {
                return stay(
                    id: stayID,
                    duty: duty,
                    hotelCode: hotelCode,
                    stationIATA: stationIATA,
                    hotel: hotel,
                    arrivalLeg: arrivalLeg,
                    departureContext: nextContext,
                    timingStatus: .sequenceMismatch(
                        nextOriginIATA: nextContext.leg.originIATA
                    ),
                    reportTimeSource: nil,
                    selectedAlternative: nil,
                    requiresConfirmation: station?.alternatives.isEmpty == false,
                    alternatives: station?.alternatives.map(\.label) ?? []
                )
            }
            guard let station else {
                return stay(
                    id: stayID,
                    duty: duty,
                    hotelCode: hotelCode,
                    stationIATA: stationIATA,
                    hotel: hotel,
                    arrivalLeg: arrivalLeg,
                    departureContext: nextContext,
                    timingStatus: .stationDataMissing,
                    reportTimeSource: nil,
                    selectedAlternative: nil,
                    requiresConfirmation: false,
                    alternatives: []
                )
            }
            guard let departure = nextContext.leg.departure.instant else {
                return stay(
                    id: stayID,
                    duty: duty,
                    hotelCode: hotelCode,
                    stationIATA: stationIATA,
                    hotel: hotel,
                    arrivalLeg: arrivalLeg,
                    departureContext: nextContext,
                    timingStatus: .departureTimeUnresolved,
                    reportTimeSource: nil,
                    selectedAlternative: nil,
                    requiresConfirmation: !station.alternatives.isEmpty,
                    alternatives: station.alternatives.map(\.label)
                )
            }

            let reportSelection = reportTime(
                arrival: arrivalContext.leg.arrival.instant,
                departure: departure,
                departureDuty: nextContext.duty,
                arrivalDutyID: duty.id
            )
            let alternative = automaticAlternative(
                flightNumber: nextContext.leg.flightNumber,
                alternatives: station.alternatives
            )
            let selectedAlternative = alternative.match?.label
                ?? defaultAlternativeTag
            guard let details = TimeCalculator.calculateDetails(
                departure: departure,
                reportTime: reportSelection.time,
                station: station,
                selectedAlternative: selectedAlternative,
                defaultAlternativeTag: defaultAlternativeTag,
                stationHolidays: station.holidays ?? []
            ) else {
                return stay(
                    id: stayID,
                    duty: duty,
                    hotelCode: hotelCode,
                    stationIATA: stationIATA,
                    hotel: hotel,
                    arrivalLeg: arrivalLeg,
                    departureContext: nextContext,
                    timingStatus: .calculationUnavailable,
                    reportTimeSource: reportSelection.source,
                    selectedAlternative: alternative.match?.label,
                    requiresConfirmation: alternative.requiresConfirmation,
                    alternatives: station.alternatives.map(\.label)
                )
            }

            return stay(
                id: stayID,
                duty: duty,
                hotelCode: hotelCode,
                stationIATA: stationIATA,
                hotel: hotel,
                arrivalLeg: arrivalLeg,
                departureContext: nextContext,
                timingStatus: .calculated(details),
                reportTimeSource: reportSelection.source,
                selectedAlternative: alternative.match?.label,
                requiresConfirmation: alternative.requiresConfirmation,
                alternatives: station.alternatives.map(\.label)
            )
        }
    }

    private struct LegContext {
        let duty: RosterDuty
        let leg: RosterLeg
    }

    private static func stayStationIATA(
        hotelCode: String,
        duty: RosterDuty
    ) -> String {
        let prefix = String(hotelCode.prefix(3))
        if isIATA(prefix),
           duty.legs.contains(where: { $0.destinationIATA == prefix }) {
            return prefix
        }
        return duty.legs.last?.destinationIATA ?? prefix
    }

    private static func reportTime(
        arrival: Date?,
        departure: Date,
        departureDuty: RosterDuty,
        arrivalDutyID: String
    ) -> (time: Date?, source: RosterReportTimeSource) {
        let rosterReport = departureDuty.start
        let followsArrival = arrival.map { rosterReport > $0 } ?? true
        if departureDuty.id != arrivalDutyID,
           followsArrival,
           rosterReport <= departure {
            return (rosterReport, .roster)
        }
        return (nil, .standardBeforeDeparture)
    }

    private static func automaticAlternative(
        flightNumber: String,
        alternatives: [TransportAlternative]
    ) -> (match: TransportAlternative?, requiresConfirmation: Bool) {
        let normalizedFlight = normalizedFlightNumber(flightNumber)
        let matches = alternatives.filter { alternative in
            alternative.label
                .uppercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .map(normalizedFlightNumber)
                .contains(normalizedFlight)
        }
        if matches.count == 1 {
            return (matches[0], false)
        }
        return (nil, !alternatives.isEmpty)
    }

    private static func normalizedFlightNumber(_ value: String) -> String {
        let compact = value.uppercased().filter {
            $0.isLetter || $0.isNumber
        }
        let prefix = compact.prefix(while: \Character.isLetter)
        let remainder = compact.dropFirst(prefix.count)
        let digits = remainder.prefix(while: \Character.isNumber)
        guard !prefix.isEmpty, !digits.isEmpty else {
            return compact
        }

        let significantDigits = digits.drop(while: { $0 == "0" })
        let canonicalDigits = significantDigits.isEmpty
            ? "0"
            : String(significantDigits)
        return String(prefix)
            + canonicalDigits
            + String(remainder.dropFirst(digits.count))
    }

    private static func isIATA(_ value: String) -> Bool {
        value.utf8.count == 3 && value.utf8.allSatisfy { byte in
            (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
        }
    }

    private static func stay(
        id: String,
        duty: RosterDuty,
        hotelCode: String,
        stationIATA: String,
        hotel: Hotel?,
        arrivalLeg: RosterLeg?,
        departureContext: LegContext?,
        timingStatus: RosterStayTimingStatus,
        reportTimeSource: RosterReportTimeSource?,
        selectedAlternative: String?,
        requiresConfirmation: Bool,
        alternatives: [String]
    ) -> RosterStay {
        RosterStay(
            id: id,
            arrivalDutyID: duty.id,
            hotelCode: hotelCode,
            stationIATA: stationIATA,
            stationTimeZoneIdentifier: arrivalLeg?.arrival.timeZoneIdentifier
                ?? departureContext?.leg.departure.timeZoneIdentifier,
            hotelName: hotel?.displayName,
            hotelCity: hotel?.city,
            hotelCountry: hotel?.country,
            arrivalLeg: arrivalLeg,
            departureDutyID: departureContext?.duty.id,
            departureLeg: departureContext?.leg,
            timingStatus: timingStatus,
            reportTimeSource: reportTimeSource,
            automaticallySelectedAlternative: selectedAlternative,
            requiresTransportConfirmation: requiresConfirmation,
            availableTransportAlternatives: alternatives
        )
    }
}

struct RosterTimelineFocusResolver {
    static func dutyID(
        duties: [RosterDuty],
        stays: [RosterStay],
        now: Date
    ) -> String? {
        let sorted = duties.sorted {
            $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start
        }

        if let currentFlight = sorted.first(where: {
            $0.kind == .flight && $0.start <= now && $0.end >= now
        }) {
            return currentFlight.id
        }

        let dutiesByID = Dictionary(
            uniqueKeysWithValues: sorted.map { ($0.id, $0) }
        )
        let activeStays = stays.filter { stay in
            guard let arrivalDuty = dutiesByID[stay.arrivalDutyID],
                  arrivalDuty.end < now else {
                return false
            }

            switch stay.timingStatus {
            case .calculated(let details):
                return details.departure > now
            case .nextDepartureMissing:
                return true
            case .arrivalMissing, .sequenceMismatch, .stationDataMissing,
                 .departureTimeUnresolved, .calculationUnavailable:
                return stay.departureLeg?.departure.instant.map {
                    $0 > now
                } ?? false
            }
        }
        if let activeStay = activeStays.max(by: {
            (dutiesByID[$0.arrivalDutyID]?.end ?? .distantPast)
                < (dutiesByID[$1.arrivalDutyID]?.end ?? .distantPast)
        }) {
            return activeStay.arrivalDutyID
        }


        if let currentActivity = sorted.first(where: {
            $0.kind == .activity && $0.start <= now && $0.end >= now
        }) {
            return currentActivity.id
        }

        return sorted.first { $0.end >= now }?.id ?? sorted.last?.id
    }
}
