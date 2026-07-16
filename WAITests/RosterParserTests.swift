import Foundation
import Testing
@testable import WAI

struct TAPRosterParserTests {
    private let importedAt = Date(timeIntervalSince1970: 1_784_112_400)
    private let timeZones = [
        "LIS": "Europe/Lisbon",
        "CPH": "Europe/Copenhagen",
        "YYZ": "America/Toronto"
    ]

    @Test func parsesTAPRotationIntoResolvedLocalLegs() throws {
        let result = try parse(sampleCalendar)

        #expect(result.issues.isEmpty)
        #expect(result.document.isValid)
        #expect(result.document.source.company == .tap)
        #expect(result.document.source.crewIdentifier == "12345.6")
        #expect(result.document.source.sourceName == "sanitized-roster.ics")
        #expect(result.document.source.sha256.count == 64)
        #expect(result.document.duties.count == 1)

        let duty = try #require(result.document.duties.first)
        #expect(duty.id == "rotation-1")
        #expect(duty.activityCode == "2CPH1801P")
        #expect(duty.kind == .flight)
        #expect(duty.hotelCode == "CPHRDS")
        #expect(duty.start == utcDate(2026, 7, 18, 16, 25))
        #expect(duty.end == utcDate(2026, 7, 20, 8, 30))
        #expect(duty.legs.count == 2)

        let outbound = try #require(duty.legs.first)
        #expect(outbound.flightNumber == "TP0756")
        #expect(outbound.originIATA == "LIS")
        #expect(outbound.destinationIATA == "CPH")
        #expect(outbound.departure.instant == utcDate(2026, 7, 18, 17, 25))
        #expect(outbound.arrival.instant == utcDate(2026, 7, 18, 21, 5))
        #expect(outbound.aircraftRegistration == "CSTVB")
        #expect(outbound.aircraftName == "TEST AIRCRAFT")
        #expect(outbound.passengerLoad == "2/0/159")
        #expect(outbound.cosmicRadiation == 3.67)
        #expect(outbound.crew.count == 2)

        let inbound = try #require(duty.legs.dropFirst().first)
        #expect(inbound.departure.instant == utcDate(2026, 7, 20, 4, 0))
        #expect(inbound.arrival.instant == utcDate(2026, 7, 20, 8, 0))
        #expect(inbound.crew.last?.isDeadhead == true)

        #expect(result.document.coverage.start == utcDate(2026, 7, 17, 23, 0))
        #expect(result.document.coverage.end == utcDate(2026, 7, 20, 23, 0))
    }

    @Test func activityWithoutFlightBlocksRemainsGeneric() throws {
        let calendar = sampleCalendar.replacingOccurrences(
            of: flightDescription,
            with: "ACTIVIDADE: DFD"
        )
        .replacingOccurrences(of: "SUMMARY:2CPH1801P", with: "SUMMARY:DFD")

        let result = try parse(calendar)
        let duty = try #require(result.document.duties.first)

        #expect(duty.activityCode == "DFD")
        #expect(duty.kind == .activity)
        #expect(duty.legs.isEmpty)
        #expect(duty.hotelCode == nil)
    }

    @Test func floatingFlightDutyUsesLocalTimeZonesAtBothEndpoints() throws {
        let result = try parse(outboundCalendar)
        let duty = try #require(result.document.duties.first)
        let leg = try #require(duty.legs.first)

        #expect(result.document.isValid)
        #expect(duty.start == utcDate(2026, 7, 30, 8, 25))
        #expect(duty.end == utcDate(2026, 7, 30, 18, 0))
        #expect(duty.startTimeZoneIdentifier == "Europe/Lisbon")
        #expect(duty.endTimeZoneIdentifier == "America/Toronto")
        #expect(leg.departure.instant == utcDate(2026, 7, 30, 9, 40))
        #expect(leg.arrival.instant == utcDate(2026, 7, 30, 18, 0))
    }

    @Test func floatingFlightDutyUsesRemoteOriginForItsStart() throws {
        let result = try parse(inboundCalendar)
        let duty = try #require(result.document.duties.first)

        #expect(result.document.isValid)
        #expect(duty.start == utcDate(2026, 7, 31, 20, 0))
        #expect(duty.end == utcDate(2026, 8, 1, 5, 0))
        #expect(duty.startTimeZoneIdentifier == "America/Toronto")
        #expect(duty.endTimeZoneIdentifier == "Europe/Lisbon")
        #expect(result.document.coverage.start == utcDate(2026, 7, 30, 23, 0))
    }

    @Test func explicitPropertyTimeZonesRemainAuthoritative() throws {
        let explicit = outboundCalendar
            .replacingOccurrences(
                of: "DTSTART:20260730T092500",
                with: "DTSTART;TZID=Europe/Lisbon:20260730T092500"
            )
            .replacingOccurrences(
                of: "DTEND:20260730T140000",
                with: "DTEND;TZID=Europe/Lisbon:20260730T190000"
            )

        let result = try parse(explicit)
        let duty = try #require(result.document.duties.first)

        #expect(result.document.isValid)
        #expect(duty.start == utcDate(2026, 7, 30, 8, 25))
        #expect(duty.end == utcDate(2026, 7, 30, 18, 0))
    }

    @Test func carryInDutyOverlappingDeclaredCoverageIsAccepted() throws {
        let result = try parse(carryInCalendar)
        let duty = try #require(result.document.duties.first)

        #expect(result.document.isValid)
        #expect(duty.start < result.document.coverage.start)
        #expect(duty.end > result.document.coverage.start)
    }

    @Test func unknownStationTimeZoneNeverGuessesAnInstant() throws {
        let result = try TAPRosterParser.parse(
            data: Data(sampleCalendar.utf8),
            sourceName: "sanitized-roster.ics",
            stationTimeZones: ["LIS": "Europe/Lisbon"],
            importedAt: importedAt
        )

        #expect(result.document.isValid)
        #expect(result.issues.count == 2)
        #expect(result.issues.allSatisfy { $0.stationIATA == "CPH" })
        let duty = try #require(result.document.duties.first)
        let outbound = try #require(duty.legs.first)
        let inbound = try #require(duty.legs.dropFirst().first)
        #expect(outbound.arrival.instant == nil)
        #expect(outbound.arrival.timeZoneIdentifier == nil)
        #expect(inbound.departure.instant == nil)
        #expect(inbound.arrival.instant != nil)
    }

    @Test func unresolvedStationStillRequiresARealLocalDate() {
        let malformed = sampleCalendar.replacingOccurrences(
            of: "18/07/2026 - 23:05 LCL",
            with: "31/02/2026 - 23:05 LCL"
        )

        #expect(throws: TAPRosterParserError.invalidDocument) {
            try TAPRosterParser.parse(
                data: Data(malformed.utf8),
                sourceName: "sanitized-roster.ics",
                stationTimeZones: ["LIS": "Europe/Lisbon"],
                importedAt: importedAt
            )
        }
    }

    @Test func foldedDescriptionLineIsUnfoldedBeforeParsing() throws {
        let folded = sampleCalendar.replacingOccurrences(
            of: "\\nChegada:",
            with: "\r\n \\nChegada:"
        )

        let result = try parse(folded)

        #expect(result.document.duties.first?.legs.count == 2)
    }

    @Test func malformedFlightFailsInsteadOfImportingPartialTiming() {
        let malformed = sampleCalendar.replacingOccurrences(
            of: "Destino:\tCPH - Copenhagen",
            with: "Destino:\tNOT AN AIRPORT"
        )

        #expect(throws: TAPRosterParserError.self) {
            try parse(malformed)
        }
    }

    @Test func nonexistentLocalDSTTimeIsRejected() {
        let malformed = sampleCalendar.replacingOccurrences(
            of: "20/07/2026 - 06:00 LCL",
            with: "29/03/2026 - 02:30 LCL"
        )

        #expect(throws: TAPRosterParserError.self) {
            try parse(malformed)
        }
    }

    @Test func repeatedLocalDSTTimeIsRejectedInsteadOfGuessed() {
        let ambiguous = sampleCalendar
            .replacingOccurrences(
                of: "18-07-2026 a 20-07-2026",
                with: "24-10-2026 a 25-10-2026"
            )
            .replacingOccurrences(
                of: "DTSTART:20260718T172500",
                with: "DTSTART:20261024T172500"
            )
            .replacingOccurrences(
                of: "DTEND:20260720T093000",
                with: "DTEND:20261025T070000"
            )
            .replacingOccurrences(
                of: "18/07/2026 - 18:25 LCL",
                with: "24/10/2026 - 18:25 LCL"
            )
            .replacingOccurrences(
                of: "18/07/2026 - 23:05 LCL",
                with: "24/10/2026 - 23:05 LCL"
            )
            .replacingOccurrences(
                of: "20/07/2026 - 06:00 LCL",
                with: "25/10/2026 - 02:30 LCL"
            )
            .replacingOccurrences(
                of: "20/07/2026 - 09:00 LCL",
                with: "25/10/2026 - 05:30 LCL"
            )

        #expect(throws: TAPRosterParserError.invalidFlight(
            dutyID: "rotation-1",
            flightNumber: "TP0757",
            field: "departure"
        )) {
            try parse(ambiguous)
        }
    }

    @Test func resolvedLegOutsideDutyRangeIsRejected() {
        let malformed = sampleCalendar.replacingOccurrences(
            of: "20/07/2026 - 09:00 LCL",
            with: "20/07/2026 - 12:00 LCL"
        )

        #expect(throws: TAPRosterParserError.invalidDocument) {
            try parse(malformed)
        }
    }

    @Test func dutyOutsideDeclaredCoverageIsRejected() {
        let malformed = sampleCalendar.replacingOccurrences(
            of: "18-07-2026 a 20-07-2026",
            with: "01-07-2026 a 02-07-2026"
        )

        #expect(throws: TAPRosterParserError.invalidDocument) {
            try parse(malformed)
        }
    }

    @Test func duplicateDutyUIDIsRejected() {
        let eventStart = sampleCalendar.range(of: "BEGIN:VEVENT")!.lowerBound
        let eventEnd = sampleCalendar.range(of: "END:VEVENT")!.upperBound
        let event = String(sampleCalendar[eventStart..<eventEnd])
        let duplicate = sampleCalendar.replacingOccurrences(
            of: "END:VCALENDAR",
            with: "\(event)\nEND:VCALENDAR"
        )

        #expect(throws: TAPRosterParserError.duplicateDutyID("rotation-1")) {
            try parse(duplicate)
        }
    }

    @Test func unrelatedCalendarIsRejected() {
        let unrelated = sampleCalendar
            .replacingOccurrences(
                of: "PRODID:-//TAP Portugal - Portal DOV",
                with: "PRODID:-//Example Calendar"
            )
            .replacingOccurrences(
                of: "X-WR-CALNAME:Escala TAP",
                with: "X-WR-CALNAME:Personal"
            )

        #expect(throws: TAPRosterParserError.unsupportedCompany) {
            try parse(unrelated)
        }
    }

    private func parse(_ calendar: String) throws -> RosterImportResult {
        try TAPRosterParser.parse(
            data: Data(calendar.utf8),
            sourceName: "sanitized-roster.ics",
            stationTimeZones: timeZones,
            importedAt: importedAt
        )
    }

    private func utcDate(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    private var sampleCalendar: String {
        """
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//TAP Portugal - Portal DOV
        X-WR-CALNAME:Escala TAP 18-07-2026 a 20-07-2026
        X-WR-CALDESC:Escala TAP do Tripulante 12345.6 (18-07-2026 a 20-07-2026)
        BEGIN:VEVENT
        TZID:Europe-Lisbon
        DTSTART:20260718T172500
        DTEND:20260720T093000
        SUMMARY:2CPH1801P
        DESCRIPTION:\(flightDescription)
        UID:rotation-1
        END:VEVENT
        END:VCALENDAR
        """
    }

    private var outboundCalendar: String {
        """
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//TAP Portugal - Portal DOV
        X-WR-CALNAME:Escala TAP 30-07-2026 a 30-07-2026
        BEGIN:VEVENT
        TZID:Europe-Lisbon
        DTSTART:20260730T092500
        DTEND:20260730T140000
        SUMMARY:1YYZ3001P
        DESCRIPTION:\(outboundDescription)
        UID:outbound-rotation
        END:VEVENT
        END:VCALENDAR
        """
    }

    private var inboundCalendar: String {
        """
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//TAP Portugal - Portal DOV
        X-WR-CALNAME:Escala TAP 31-07-2026 a 01-08-2026
        BEGIN:VEVENT
        TZID:Europe-Lisbon
        DTSTART:20260731T160000
        DTEND:20260801T060000
        SUMMARY:1LIS3101P
        DESCRIPTION:\(inboundDescription)
        UID:inbound-rotation
        END:VEVENT
        END:VCALENDAR
        """
    }

    private var carryInCalendar: String {
        """
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//TAP Portugal - Portal DOV
        X-WR-CALNAME:Escala TAP 01-07-2026 a 31-07-2026
        BEGIN:VEVENT
        TZID:Europe-Lisbon
        DTSTART:20260630T100000
        DTEND:20260701T100000
        SUMMARY:DFD
        DESCRIPTION:ACTIVIDADE: DFD
        UID:carry-in-activity
        END:VEVENT
        END:VCALENDAR
        """
    }

    private var outboundDescription: String {
        "ACTIVIDADE: 1YYZ3001P\\n\\nVOO TP0001\\nSaida:\t\t30/07/2026 - 10:40 LCL\\nChegada:\t30/07/2026 - 14:00 LCL\\n\\nOrigem:\tLIS - Lisbon\\nDestino:\tYYZ - Toronto"
    }

    private var inboundDescription: String {
        "ACTIVIDADE: 1LIS3101P\\n\\nVOO TP0002\\nSaida:\t\t31/07/2026 - 17:00 LCL\\nChegada:\t01/08/2026 - 06:00 LCL\\n\\nOrigem:\tYYZ - Toronto\\nDestino:\tLIS - Lisbon"
    }

    private var flightDescription: String {
        "ACTIVIDADE: 2CPH1801P\\n\\nVOO TP0756\\nSaida:\t\t18/07/2026 - 18:25 LCL\\nChegada:\t18/07/2026 - 23:05 LCL\\n\\nOrigem:\tLIS - Humberto Delgado\\nDestino:\tCPH - Copenhagen\\n\\nMatricula:\tCSTVB - TEST AIRCRAFT\\nPax:\t\t2/0/159\\n\\nRadiacao Cosmica:\t\t3.67\\n\\nTripulacao:\\n\\n10000.1\t\tCPT\tCAPTAIN TEST\\n12345.6\t\tCAB\tCREW MEMBER\\n\\nHOTEL: CPHRDS\\n\\nVOO TP0757\\nSaida:\t\t20/07/2026 - 06:00 LCL\\nChegada:\t20/07/2026 - 09:00 LCL\\n\\nOrigem:\tCPH - Copenhagen\\nDestino:\tLIS - Humberto Delgado\\n\\nMatricula:\tCSTVC - RETURN AIRCRAFT\\nPax:\t\t5/0/150\\n\\nRadiacao Cosmica:\t\t4\\n\\nTripulacao:\\n\\n10000.1\t\tCPT\tCAPTAIN TEST\\n12345.6\t\tCAB\tCREW MEMBER\t(DHC)"
    }
}
