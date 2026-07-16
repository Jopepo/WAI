import Foundation
import Testing
@testable import WAI

struct RosterTimelineTests {
    @Test func parsedPortalTimeZonesFlowIntoRemoteStayTiming() throws {
        let result = try TAPRosterParser.parse(
            data: Data(remoteStayCalendar.utf8),
            sourceName: "sanitized-roster.ics",
            stationTimeZones: [
                "LIS": "Europe/Lisbon",
                "YYZ": "America/Toronto"
            ],
            importedAt: date("Europe/Lisbon", 2026, 7, 29, 12, 0)
        )

        let stay = try #require(
            RosterTimelineBuilder.stays(
                duties: result.document.duties,
                stations: [
                    fixedStation(
                        iata: "YYZ",
                        timeZone: "America/Toronto",
                        minutes: 45
                    )
                ],
                hotels: [hotel(iata: "YYZ", name: "TEST HOTEL")]
            ).first
        )
        guard case .calculated(let details) = stay.timingStatus else {
            Issue.record("Expected calculated timing")
            return
        }

        #expect(result.document.isValid)
        #expect(stay.stationIATA == "YYZ")
        #expect(stay.hotelCode == "YYZHTL")
        #expect(stay.reportTimeSource == .roster)
        #expect(
            details.report
                == date("America/Toronto", 2026, 7, 31, 16, 0)
        )
        #expect(
            details.pickup.earliest
                == date("America/Toronto", 2026, 7, 31, 15, 15)
        )
        #expect(
            details.wakeup.earliest
                == date("America/Toronto", 2026, 7, 31, 14, 15)
        )
    }

    @Test func cphStayUsesRosterReportForWakeupAndPickup() throws {
        let outbound = duty(
            id: "outbound",
            start: date("Europe/Lisbon", 2026, 7, 15, 6, 0),
            end: date("Europe/Copenhagen", 2026, 7, 15, 12, 15),
            hotelCode: "CPHRDS",
            legs: [
                leg(
                    id: "lis-cph",
                    flight: "TP752",
                    origin: "LIS",
                    destination: "CPH",
                    departure: local("Europe/Lisbon", 2026, 7, 15, 7, 0),
                    arrival: local("Europe/Copenhagen", 2026, 7, 15, 11, 45)
                )
            ]
        )
        let report = date("Europe/Copenhagen", 2026, 7, 17, 7, 0)
        let inbound = duty(
            id: "inbound",
            start: report,
            end: date("Europe/Lisbon", 2026, 7, 17, 11, 0),
            legs: [
                leg(
                    id: "cph-lis",
                    flight: "TP753",
                    origin: "CPH",
                    destination: "LIS",
                    departure: local("Europe/Copenhagen", 2026, 7, 17, 8, 0),
                    arrival: local("Europe/Lisbon", 2026, 7, 17, 10, 45)
                )
            ]
        )

        let stays = RosterTimelineBuilder.stays(
            duties: [outbound, inbound],
            stations: [fixedStation(iata: "CPH", timeZone: "Europe/Copenhagen", minutes: 35)],
            hotels: [hotel(iata: "CPH", name: "SCANDIC SPECTRUM")]
        )
        let stay = try #require(stays.first)
        guard case .calculated(let details) = stay.timingStatus else {
            Issue.record("Expected calculated timing")
            return
        }

        #expect(stay.hotelCode == "CPHRDS")
        #expect(stay.hotelName == "Scandic Spectrum")
        #expect(stay.reportTimeSource == .roster)
        #expect(details.report == report)
        #expect(details.pickup.earliest == date("Europe/Copenhagen", 2026, 7, 17, 6, 25))
        #expect(details.wakeup.earliest == date("Europe/Copenhagen", 2026, 7, 17, 5, 25))
        #expect(details.minimumTransportMinutes == 35)
    }

    @Test func rangeRuleProducesWakeupAndPickupWindows() throws {
        let outbound = simpleStayArrival(
            station: "GIG",
            hotelCode: "GIGHTL",
            arrivalTimeZone: "America/Sao_Paulo"
        )
        let report = date("America/Sao_Paulo", 2026, 7, 17, 10, 0)
        let inbound = duty(
            id: "inbound",
            start: report,
            end: date("America/Sao_Paulo", 2026, 7, 17, 18, 0),
            legs: [
                leg(
                    id: "gig-lis",
                    flight: "TP74",
                    origin: "GIG",
                    destination: "LIS",
                    departure: local("America/Sao_Paulo", 2026, 7, 17, 11, 0),
                    arrival: local("Europe/Lisbon", 2026, 7, 17, 21, 0)
                )
            ]
        )
        let station = rangeStation(
            iata: "GIG",
            timeZone: "America/Sao_Paulo",
            minimum: 0,
            maximum: 110
        )

        let stay = try #require(
            RosterTimelineBuilder.stays(
                duties: [outbound, inbound],
                stations: [station],
                hotels: []
            ).first
        )
        guard case .calculated(let details) = stay.timingStatus else {
            Issue.record("Expected calculated timing")
            return
        }

        #expect(details.usesTransportRange)
        #expect(details.pickup.earliest == date("America/Sao_Paulo", 2026, 7, 17, 8, 10))
        #expect(details.pickup.latest == date("America/Sao_Paulo", 2026, 7, 17, 10, 0))
        #expect(details.wakeup.earliest == date("America/Sao_Paulo", 2026, 7, 17, 7, 10))
        #expect(details.wakeup.latest == date("America/Sao_Paulo", 2026, 7, 17, 9, 0))
    }

    @Test func truncatedRosterDoesNotInventNextDeparture() throws {
        let outbound = simpleStayArrival(
            station: "CPH",
            hotelCode: "CPHRDS",
            arrivalTimeZone: "Europe/Copenhagen"
        )

        let stay = try #require(
            RosterTimelineBuilder.stays(
                duties: [outbound],
                stations: [fixedStation(iata: "CPH", timeZone: "Europe/Copenhagen", minutes: 35)],
                hotels: []
            ).first
        )

        #expect(stay.timingStatus == .nextDepartureMissing)
        #expect(stay.departureLeg == nil)
    }

    @Test func mismatchedNextOriginIsReportedInsteadOfSkipped() throws {
        let outbound = simpleStayArrival(
            station: "CPH",
            hotelCode: "CPHRDS",
            arrivalTimeZone: "Europe/Copenhagen"
        )
        let unrelated = duty(
            id: "unrelated",
            start: date("Europe/Stockholm", 2026, 7, 17, 7, 0),
            end: date("Europe/Lisbon", 2026, 7, 17, 11, 0),
            legs: [
                leg(
                    id: "arn-lis",
                    flight: "TP781",
                    origin: "ARN",
                    destination: "LIS",
                    departure: local("Europe/Stockholm", 2026, 7, 17, 8, 0),
                    arrival: local("Europe/Lisbon", 2026, 7, 17, 10, 45)
                )
            ]
        )

        let stay = try #require(
            RosterTimelineBuilder.stays(
                duties: [outbound, unrelated],
                stations: [fixedStation(iata: "CPH", timeZone: "Europe/Copenhagen", minutes: 35)],
                hotels: []
            ).first
        )

        #expect(stay.timingStatus == .sequenceMismatch(nextOriginIATA: "ARN"))
    }

    @Test func paddedFlightNumberSelectsMatchingAlternative() throws {
        let outbound = simpleStayArrival(
            station: "GRU",
            hotelCode: "GRUHTL",
            arrivalTimeZone: "America/Sao_Paulo"
        )
        let inbound = duty(
            id: "inbound",
            start: date("America/Sao_Paulo", 2026, 7, 17, 10, 0),
            end: date("America/Sao_Paulo", 2026, 7, 17, 18, 0),
            legs: [
                leg(
                    id: "gru-lis",
                    flight: "TP0088",
                    origin: "GRU",
                    destination: "LIS",
                    departure: local("America/Sao_Paulo", 2026, 7, 17, 11, 0),
                    arrival: local("Europe/Lisbon", 2026, 7, 17, 21, 0)
                )
            ]
        )
        let station = fixedStation(
            iata: "GRU",
            timeZone: "America/Sao_Paulo",
            minutes: 90,
            alternatives: [
                TransportAlternative(label: "TP88 / TP94", transportMinutes: 100),
                TransportAlternative(
                    label: "Specific locally coordinated Hotel-Airport transfer",
                    transportMinutes: 100
                )
            ]
        )

        let stay = try #require(
            RosterTimelineBuilder.stays(
                duties: [outbound, inbound],
                stations: [station],
                hotels: []
            ).first
        )
        guard case .calculated(let details) = stay.timingStatus else {
            Issue.record("Expected calculated timing")
            return
        }

        #expect(stay.automaticallySelectedAlternative == "TP88 / TP94")
        #expect(!stay.requiresTransportConfirmation)
        #expect(details.maximumTransportMinutes == 100)
        #expect(details.appliedRuleLabel == "TP88 / TP94")
    }

    @Test func sameDutyHotelRotationUsesStandardReportBeforeDeparture() throws {
        let rotation = duty(
            id: "rotation",
            start: date("Europe/Lisbon", 2026, 7, 18, 17, 25),
            end: date("Europe/Lisbon", 2026, 7, 20, 9, 30),
            hotelCode: "CPHRDS",
            legs: [
                leg(
                    id: "lis-cph",
                    flight: "TP0756",
                    origin: "LIS",
                    destination: "CPH",
                    departure: local("Europe/Lisbon", 2026, 7, 18, 18, 25),
                    arrival: local("Europe/Copenhagen", 2026, 7, 18, 23, 5)
                ),
                leg(
                    id: "cph-lis",
                    flight: "TP0757",
                    origin: "CPH",
                    destination: "LIS",
                    departure: local("Europe/Copenhagen", 2026, 7, 20, 6, 0),
                    arrival: local("Europe/Lisbon", 2026, 7, 20, 9, 0)
                )
            ]
        )

        let stay = try #require(
            RosterTimelineBuilder.stays(
                duties: [rotation],
                stations: [
                    fixedStation(
                        iata: "CPH",
                        timeZone: "Europe/Copenhagen",
                        minutes: 35
                    )
                ],
                hotels: []
            ).first
        )
        guard case .calculated(let details) = stay.timingStatus else {
            Issue.record("Expected calculated timing")
            return
        }

        #expect(stay.arrivalLeg?.id == "lis-cph")
        #expect(stay.departureLeg?.id == "cph-lis")
        #expect(stay.departureDutyID == rotation.id)
        #expect(stay.reportTimeSource == .standardBeforeDeparture)
        #expect(details.report == date("Europe/Copenhagen", 2026, 7, 20, 5, 0))
        #expect(details.pickup.earliest == date("Europe/Copenhagen", 2026, 7, 20, 4, 25))
        #expect(details.wakeup.earliest == date("Europe/Copenhagen", 2026, 7, 20, 3, 25))
    }

    @Test func nightRuleUsesLocalDepartureAcrossMidnight() throws {
        let outbound = simpleStayArrival(
            station: "EWR",
            hotelCode: "EWRHTL",
            arrivalTimeZone: "America/New_York"
        )
        let inbound = duty(
            id: "inbound",
            start: date("America/New_York", 2026, 7, 17, 23, 30),
            end: date("Europe/Lisbon", 2026, 7, 18, 12, 0),
            legs: [
                leg(
                    id: "ewr-lis",
                    flight: "TP0202",
                    origin: "EWR",
                    destination: "LIS",
                    departure: local("America/New_York", 2026, 7, 18, 0, 30),
                    arrival: local("Europe/Lisbon", 2026, 7, 18, 12, 0)
                )
            ]
        )
        let station = timeDependentStation(
            iata: "EWR",
            timeZone: "America/New_York",
            rules: [
                TimeRule(
                    label: "Night 21:00-06:00",
                    fromLocal: "21:00",
                    toLocal: "06:00",
                    weekdaysOnly: nil,
                    weekendsAndHolidaysOnly: nil,
                    publicHolidaysOnly: nil,
                    transportMinutes: 70
                ),
                TimeRule(
                    label: "Standard",
                    fromLocal: "06:01",
                    toLocal: "20:59",
                    weekdaysOnly: nil,
                    weekendsAndHolidaysOnly: nil,
                    publicHolidaysOnly: nil,
                    transportMinutes: 90
                )
            ]
        )

        let stay = try #require(
            RosterTimelineBuilder.stays(
                duties: [outbound, inbound],
                stations: [station],
                hotels: []
            ).first
        )
        guard case .calculated(let details) = stay.timingStatus else {
            Issue.record("Expected calculated timing")
            return
        }

        #expect(details.appliedRuleLabel == "Night 21:00-06:00")
        #expect(details.pickup.earliest == date("America/New_York", 2026, 7, 17, 22, 20))
        #expect(details.wakeup.earliest == date("America/New_York", 2026, 7, 17, 21, 20))
    }

    @Test func publicHolidayUsesStationLocalDepartureDate() throws {
        let outbound = duty(
            id: "outbound",
            start: date("Europe/Lisbon", 2026, 9, 5, 6, 0),
            end: date("America/Sao_Paulo", 2026, 9, 5, 15, 0),
            hotelCode: "GRUHTL",
            legs: [
                leg(
                    id: "lis-gru",
                    flight: "TP0087",
                    origin: "LIS",
                    destination: "GRU",
                    departure: local("Europe/Lisbon", 2026, 9, 5, 7, 0),
                    arrival: local("America/Sao_Paulo", 2026, 9, 5, 14, 0)
                )
            ]
        )
        let inbound = duty(
            id: "inbound",
            start: date("America/Sao_Paulo", 2026, 9, 7, 10, 0),
            end: date("Europe/Lisbon", 2026, 9, 7, 21, 0),
            legs: [
                leg(
                    id: "gru-lis",
                    flight: "TP0089",
                    origin: "GRU",
                    destination: "LIS",
                    departure: local("America/Sao_Paulo", 2026, 9, 7, 11, 0),
                    arrival: local("Europe/Lisbon", 2026, 9, 7, 21, 0)
                )
            ]
        )
        let station = conditionalStation(
            iata: "GRU",
            timeZone: "America/Sao_Paulo",
            defaultMinutes: 90,
            conditions: [
                TransportCondition(
                    label: "Weekend",
                    fromLocal: nil,
                    toLocal: nil,
                    appliesOnWeekdays: nil,
                    appliesOnWeekends: true,
                    appliesOnPublicHolidays: nil,
                    transportMinutes: 80
                ),
                TransportCondition(
                    label: "Public holiday",
                    fromLocal: nil,
                    toLocal: nil,
                    appliesOnWeekdays: nil,
                    appliesOnWeekends: nil,
                    appliesOnPublicHolidays: true,
                    transportMinutes: 80
                )
            ],
            holidays: [
                StationHoliday(
                    date: "2026-09-07",
                    name: "Independence Day"
                )
            ]
        )

        let stay = try #require(
            RosterTimelineBuilder.stays(
                duties: [outbound, inbound],
                stations: [station],
                hotels: []
            ).first
        )
        guard case .calculated(let details) = stay.timingStatus else {
            Issue.record("Expected calculated timing")
            return
        }

        #expect(details.appliedRuleLabel == "Public holiday")
        #expect(details.minimumTransportMinutes == 80)
        #expect(details.pickup.earliest == date("America/Sao_Paulo", 2026, 9, 7, 8, 40))
        #expect(details.wakeup.earliest == date("America/Sao_Paulo", 2026, 9, 7, 7, 40))
    }

    @Test func activeStayIsFocusedBeforeTheFutureReturnDuty() throws {
        let outbound = simpleStayArrival(
            station: "CPH",
            hotelCode: "CPHRDS",
            arrivalTimeZone: "Europe/Copenhagen"
        )
        let inbound = duty(
            id: "inbound",
            start: date("Europe/Copenhagen", 2026, 7, 17, 7, 0),
            end: date("Europe/Lisbon", 2026, 7, 17, 11, 0),
            legs: [
                leg(
                    id: "cph-lis",
                    flight: "TP753",
                    origin: "CPH",
                    destination: "LIS",
                    departure: local("Europe/Copenhagen", 2026, 7, 17, 8, 0),
                    arrival: local("Europe/Lisbon", 2026, 7, 17, 10, 45)
                )
            ]
        )
        let stays = RosterTimelineBuilder.stays(
            duties: [outbound, inbound],
            stations: [fixedStation(iata: "CPH", timeZone: "Europe/Copenhagen", minutes: 35)],
            hotels: []
        )

        let focused = RosterTimelineFocusResolver.dutyID(
            duties: [outbound, inbound],
            stays: stays,
            now: date("Europe/Copenhagen", 2026, 7, 16, 12, 0)
        )

        #expect(focused == outbound.id)
    }

    @Test func dutyInProgressTakesFocusWhenReportHasStarted() throws {
        let outbound = simpleStayArrival(
            station: "CPH",
            hotelCode: "CPHRDS",
            arrivalTimeZone: "Europe/Copenhagen"
        )
        let inbound = duty(
            id: "inbound",
            start: date("Europe/Copenhagen", 2026, 7, 17, 7, 0),
            end: date("Europe/Lisbon", 2026, 7, 17, 11, 0),
            legs: [
                leg(
                    id: "cph-lis",
                    flight: "TP753",
                    origin: "CPH",
                    destination: "LIS",
                    departure: local("Europe/Copenhagen", 2026, 7, 17, 8, 0),
                    arrival: local("Europe/Lisbon", 2026, 7, 17, 10, 45)
                )
            ]
        )
        let stays = RosterTimelineBuilder.stays(
            duties: [outbound, inbound],
            stations: [fixedStation(iata: "CPH", timeZone: "Europe/Copenhagen", minutes: 35)],
            hotels: []
        )

        let focused = RosterTimelineFocusResolver.dutyID(
            duties: [outbound, inbound],
            stays: stays,
            now: date("Europe/Copenhagen", 2026, 7, 17, 7, 15)
        )

        #expect(focused == inbound.id)
    }

    private func simpleStayArrival(
        station: String,
        hotelCode: String,
        arrivalTimeZone: String
    ) -> RosterDuty {
        duty(
            id: "outbound",
            start: date("Europe/Lisbon", 2026, 7, 15, 6, 0),
            end: date(arrivalTimeZone, 2026, 7, 15, 15, 0),
            hotelCode: hotelCode,
            legs: [
                leg(
                    id: "lis-\(station.lowercased())",
                    flight: "TP100",
                    origin: "LIS",
                    destination: station,
                    departure: local("Europe/Lisbon", 2026, 7, 15, 7, 0),
                    arrival: local(arrivalTimeZone, 2026, 7, 15, 14, 0)
                )
            ]
        )
    }

    private func duty(
        id: String,
        start: Date,
        end: Date,
        hotelCode: String? = nil,
        legs: [RosterLeg]
    ) -> RosterDuty {
        RosterDuty(
            id: id,
            activityCode: "FLT",
            start: start,
            end: end,
            timeZoneIdentifier: "Europe/Lisbon",
            kind: .flight,
            hotelCode: hotelCode,
            legs: legs
        )
    }

    private func leg(
        id: String,
        flight: String,
        origin: String,
        destination: String,
        departure: RosterLocalDateTime,
        arrival: RosterLocalDateTime
    ) -> RosterLeg {
        RosterLeg(
            id: id,
            flightNumber: flight,
            departure: departure,
            arrival: arrival,
            originIATA: origin,
            originName: nil,
            destinationIATA: destination,
            destinationName: nil,
            aircraftRegistration: nil,
            aircraftName: nil,
            passengerLoad: nil,
            cosmicRadiation: nil,
            crew: []
        )
    }

    private func local(
        _ timeZoneIdentifier: String,
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int
    ) -> RosterLocalDateTime {
        RosterLocalDateTime(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            timeZoneIdentifier: timeZoneIdentifier,
            instant: date(timeZoneIdentifier, year, month, day, hour, minute)
        )
    }

    private var remoteStayCalendar: String {
        let outbound = "ACTIVIDADE: 1YYZ3001P\\n\\nVOO TP0001\\nSaida: 30/07/2026 - 10:40 LCL\\nChegada: 30/07/2026 - 14:00 LCL\\nOrigem: LIS - Lisbon\\nDestino: YYZ - Toronto\\nHOTEL: YYZHTL"
        let inbound = "ACTIVIDADE: 1LIS3101P\\n\\nVOO TP0002\\nSaida: 31/07/2026 - 17:00 LCL\\nChegada: 01/08/2026 - 06:00 LCL\\nOrigem: YYZ - Toronto\\nDestino: LIS - Lisbon"
        return """
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//TAP Portugal - Portal DOV
        X-WR-CALNAME:Escala TAP 30-07-2026 a 01-08-2026
        BEGIN:VEVENT
        TZID:Europe-Lisbon
        DTSTART:20260730T092500
        DTEND:20260730T140000
        SUMMARY:1YYZ3001P
        DESCRIPTION:\(outbound)
        UID:outbound-duty
        END:VEVENT
        BEGIN:VEVENT
        TZID:Europe-Lisbon
        DTSTART:20260731T160000
        DTEND:20260801T060000
        SUMMARY:1LIS3101P
        DESCRIPTION:\(inbound)
        UID:inbound-duty
        END:VEVENT
        END:VCALENDAR
        """
    }

    private func date(
        _ timeZoneIdentifier: String,
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
        return calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    private func fixedStation(
        iata: String,
        timeZone: String,
        minutes: Int,
        alternatives: [TransportAlternative] = []
    ) -> Station {
        Station(
            iata: iata,
            icao: "TEST",
            city: iata,
            country: "Test",
            timeZone: timeZone,
            standardUtcOffset: "+00:00",
            summerUtcOffset: "+00:00",
            defaultRule: TransportRule(
                type: "fixed",
                label: nil,
                transportMinutes: minutes,
                minTransportMinutes: nil,
                maxTransportMinutes: nil,
                rules: nil,
                conditions: nil
            ),
            alternatives: alternatives,
            holidays: nil
        )
    }

    private func rangeStation(
        iata: String,
        timeZone: String,
        minimum: Int,
        maximum: Int
    ) -> Station {
        Station(
            iata: iata,
            icao: "TEST",
            city: iata,
            country: "Test",
            timeZone: timeZone,
            standardUtcOffset: "+00:00",
            summerUtcOffset: "+00:00",
            defaultRule: TransportRule(
                type: "range",
                label: nil,
                transportMinutes: nil,
                minTransportMinutes: minimum,
                maxTransportMinutes: maximum,
                rules: nil,
                conditions: nil
            ),
            alternatives: [],
            holidays: nil
        )
    }

    private func timeDependentStation(
        iata: String,
        timeZone: String,
        rules: [TimeRule]
    ) -> Station {
        Station(
            iata: iata,
            icao: "TEST",
            city: iata,
            country: "Test",
            timeZone: timeZone,
            standardUtcOffset: "+00:00",
            summerUtcOffset: "+00:00",
            defaultRule: TransportRule(
                type: "timeDependent",
                label: nil,
                transportMinutes: nil,
                minTransportMinutes: nil,
                maxTransportMinutes: nil,
                rules: rules,
                conditions: nil
            ),
            alternatives: [],
            holidays: nil
        )
    }

    private func conditionalStation(
        iata: String,
        timeZone: String,
        defaultMinutes: Int,
        conditions: [TransportCondition],
        holidays: [StationHoliday]
    ) -> Station {
        Station(
            iata: iata,
            icao: "TEST",
            city: iata,
            country: "Test",
            timeZone: timeZone,
            standardUtcOffset: "+00:00",
            summerUtcOffset: "+00:00",
            defaultRule: TransportRule(
                type: "fixed",
                label: "Weekday",
                transportMinutes: defaultMinutes,
                minTransportMinutes: nil,
                maxTransportMinutes: nil,
                rules: nil,
                conditions: conditions
            ),
            alternatives: [],
            holidays: holidays
        )
    }

    private func hotel(iata: String, name: String) -> Hotel {
        Hotel(
            iata: iata,
            icao: "TEST",
            city: iata,
            country: "Test",
            name: name,
            phone: nil,
            email: nil,
            fax: nil
        )
    }
}
