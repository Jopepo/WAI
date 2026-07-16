import Foundation
import Testing
@testable import WAI

@MainActor
struct RosterCalendarSourceTests {
    private let importedAt = Date(timeIntervalSince1970: 1_784_112_400)

    @Test func structuredFlightInGenericCalendarIsRecognized() throws {
        let snapshot = event(
            id: "flight-duty",
            calendarTitle: "Work",
            title: "LIS-CPH",
            notes: flightNotes,
            start: date(2026, 7, 15, 5, 0),
            end: date(2026, 7, 15, 13, 0)
        )

        let candidates = try TAPRosterCalendarBuilder.candidates(from: [snapshot])

        #expect(candidates.count == 1)
        #expect(candidates[0].title == "Work")
        #expect(candidates[0].eventCount == 1)
        #expect(candidates[0].payloads.count == 1)

        let result = try TAPRosterParser.parse(
            data: candidates[0].payloads[0].data,
            sourceName: candidates[0].payloads[0].sourceName,
            stationTimeZones: [
                "LIS": "Europe/Lisbon",
                "CPH": "Europe/Copenhagen"
            ],
            importedAt: importedAt
        )
        #expect(result.document.duties.count == 1)
        #expect(result.document.duties[0].legs.count == 1)
        #expect(result.document.duties[0].legs[0].flightNumber == "TP754")
        #expect(result.document.duties[0].hotelCode == "CPHRDS")
        #expect(result.document.source.sourceName == "Calendar - Work")
    }

    @Test func genericActivityAloneIsNotTreatedAsRoster() throws {
        let snapshot = event(
            id: "personal-activity",
            calendarTitle: "Personal",
            title: "DFD",
            notes: "ACTIVIDADE: DFD",
            start: date(2026, 7, 3, 10, 0),
            end: date(2026, 7, 4, 10, 0)
        )

        let candidates = try TAPRosterCalendarBuilder.candidates(from: [snapshot])

        #expect(candidates.isEmpty)
    }

    @Test func tapCalendarCanContainActivityOnlyDuties() throws {
        let snapshot = event(
            id: "tap-activity",
            calendarTitle: "Escala TAP",
            title: "DFD",
            notes: "ACTIVIDADE: DFD",
            start: date(2026, 7, 3, 10, 0),
            end: date(2026, 7, 4, 10, 0)
        )

        let candidates = try TAPRosterCalendarBuilder.candidates(from: [snapshot])
        let payload = try #require(candidates.first?.payloads.first)
        let result = try TAPRosterParser.parse(
            data: payload.data,
            sourceName: payload.sourceName,
            stationTimeZones: [:],
            importedAt: importedAt
        )

        #expect(result.document.duties.map(\.activityCode) == ["DFD"])
    }

    @Test func tapCalendarPreservesPortalEndpointWallTimes() throws {
        let snapshots = [
            event(
                id: "tap-outbound",
                calendarTitle: "Escala TAP",
                title: "1YYZ3001P",
                notes: yyzFlightNotes,
                start: date(2026, 7, 30, 9, 25),
                end: date(2026, 7, 30, 14, 0)
            ),
            event(
                id: "tap-inbound",
                calendarTitle: "Escala TAP",
                title: "1LIS3101P",
                notes: yyzInboundFlightNotes,
                start: date(2026, 7, 31, 16, 0),
                end: date(2026, 8, 1, 6, 0)
            )
        ]

        let candidate = try #require(
            TAPRosterCalendarBuilder.candidates(from: snapshots).first
        )
        let payload = try #require(candidate.payloads.first)
        let result = try TAPRosterParser.parse(
            data: payload.data,
            sourceName: payload.sourceName,
            stationTimeZones: [
                "LIS": "Europe/Lisbon",
                "YYZ": "America/Toronto"
            ],
            importedAt: importedAt
        )
        let outbound = try #require(
            result.document.duties.first { $0.id == "tap-outbound" }
        )
        let inbound = try #require(
            result.document.duties.first { $0.id == "tap-inbound" }
        )

        #expect(result.document.isValid)
        #expect(outbound.start == utcDate(2026, 7, 30, 8, 25))
        #expect(outbound.end == utcDate(2026, 7, 30, 18, 0))
        #expect(inbound.start == utcDate(2026, 7, 31, 20, 0))
        #expect(inbound.end == utcDate(2026, 8, 1, 5, 0))
    }

    @Test func genericCalendarPreservesAbsoluteEventBoundaries() throws {
        let snapshot = event(
            id: "generic-outbound",
            calendarTitle: "Work",
            title: "LIS-YYZ",
            notes: yyzFlightNotes,
            start: date(2026, 7, 30, 9, 25),
            end: date(2026, 7, 30, 19, 0)
        )

        let candidate = try #require(
            TAPRosterCalendarBuilder.candidates(from: [snapshot]).first
        )
        let payload = try #require(candidate.payloads.first)
        let result = try TAPRosterParser.parse(
            data: payload.data,
            sourceName: payload.sourceName,
            stationTimeZones: [
                "LIS": "Europe/Lisbon",
                "YYZ": "America/Toronto"
            ],
            importedAt: importedAt
        )
        let duty = try #require(result.document.duties.first)

        #expect(result.document.isValid)
        #expect(duty.start == utcDate(2026, 7, 30, 8, 25))
        #expect(duty.end == utcDate(2026, 7, 30, 18, 0))
    }

    @Test func eventsAreSplitIntoStableMonthlyPayloads() throws {
        let snapshots = [
            event(
                id: "july-duty",
                calendarTitle: "Escala TAP",
                title: "DFD",
                notes: "ACTIVIDADE: DFD",
                start: date(2026, 7, 31, 10, 0),
                end: date(2026, 7, 31, 12, 0)
            ),
            event(
                id: "august-duty",
                calendarTitle: "Escala TAP",
                title: "DOE",
                notes: "ACTIVIDADE: DOE",
                start: date(2026, 8, 1, 10, 0),
                end: date(2026, 8, 1, 12, 0)
            )
        ]

        let candidate = try #require(
            TAPRosterCalendarBuilder.candidates(from: snapshots).first
        )
        let documents = try candidate.payloads.map { payload in
            try TAPRosterParser.parse(
                data: payload.data,
                sourceName: payload.sourceName,
                stationTimeZones: [:],
                importedAt: importedAt
            ).document
        }

        #expect(candidate.payloads.count == 2)
        #expect(documents.map { month($0.coverage.start) } == [7, 8])
        #expect(documents.map { month($0.coverage.end) } == [8, 9])
    }

    @Test func rotationCrossingMonthBoundaryRemainsValid() throws {
        let snapshot = event(
            id: "cross-month-rotation",
            calendarTitle: "Escala TAP",
            title: "2CPH3101P",
            notes: crossMonthFlightNotes,
            start: date(2026, 7, 31, 21, 30),
            end: date(2026, 8, 1, 9, 0)
        )

        let candidate = try #require(
            TAPRosterCalendarBuilder.candidates(from: [snapshot]).first
        )
        let payload = try #require(candidate.payloads.first)
        let result = try TAPRosterParser.parse(
            data: payload.data,
            sourceName: payload.sourceName,
            stationTimeZones: [
                "LIS": "Europe/Lisbon",
                "CPH": "Europe/Copenhagen"
            ],
            importedAt: importedAt
        )
        let duty = try #require(result.document.duties.first)

        #expect(candidate.payloads.count == 1)
        #expect(result.document.isValid)
        #expect(month(result.document.coverage.start) == 7)
        #expect(month(result.document.coverage.end) == 8)
        #expect(duty.end > result.document.coverage.end)
        #expect(duty.legs.count == 2)
    }

    @Test func externalIdentifierKeepsDutyIDStableWhenTimeChanges() {
        let original = EventKitRosterCalendarSource.stableEventID(
            calendarID: "calendar-1",
            externalIdentifier: "portal-duty-123",
            eventIdentifier: "event-a",
            title: "LIS-CPH",
            start: date(2026, 7, 15, 5, 0),
            end: date(2026, 7, 15, 13, 0)
        )
        let updated = EventKitRosterCalendarSource.stableEventID(
            calendarID: "calendar-1",
            externalIdentifier: "portal-duty-123",
            eventIdentifier: "event-b",
            title: "LIS-CPH",
            start: date(2026, 7, 15, 5, 30),
            end: date(2026, 7, 15, 13, 30)
        )

        #expect(original == updated)
    }

    @Test func briefingEventMarkerIsStableAndDoesNotExposeLegID() throws {
        let first = try #require(
            EventKitRosterCalendarSource.briefingEventURL(
                for: "private-leg-identifier"
            )
        )
        let second = try #require(
            EventKitRosterCalendarSource.briefingEventURL(
                for: "private-leg-identifier"
            )
        )

        #expect(first == second)
        #expect(first.scheme == "wai")
        #expect(!first.absoluteString.contains("private-leg-identifier"))
        #expect(
            EventKitRosterCalendarSource.briefingEventURL(for: "") == nil
        )
    }

    @Test func oversizedCalendarNotesAreIgnoredBeforePayloadCreation() throws {
        let snapshot = event(
            id: "oversized",
            calendarTitle: "Escala TAP",
            title: "DFD",
            notes: "ACTIVIDADE: DFD\n" + String(
                repeating: "x",
                count: TAPRosterCalendarBuilder.maximumEventNotesBytes
            ),
            start: date(2026, 7, 3, 10, 0),
            end: date(2026, 7, 3, 12, 0)
        )

        let candidates = try TAPRosterCalendarBuilder.candidates(
            from: [snapshot]
        )

        #expect(candidates.isEmpty)
    }

    @Test func abnormalCalendarEventVolumeIsRejectedBeforeGrouping() {
        let snapshots = (0...TAPRosterCalendarBuilder.maximumRosterEvents)
            .map { index in
                event(
                    id: "activity-\(index)",
                    calendarTitle: "Escala TAP",
                    title: "DFD",
                    notes: "ACTIVIDADE: DFD",
                    start: date(2026, 7, 3, 10, 0),
                    end: date(2026, 7, 3, 12, 0)
                )
            }

        #expect(throws: TAPRosterCalendarBuilderError.tooManyEvents) {
            _ = try TAPRosterCalendarBuilder.candidates(from: snapshots)
        }
    }

    private func event(
        id: String,
        calendarTitle: String,
        title: String,
        notes: String,
        start: Date,
        end: Date
    ) -> WAIRosterCalendarEventSnapshot {
        WAIRosterCalendarEventSnapshot(
            id: id,
            calendarID: "calendar-1",
            calendarTitle: calendarTitle,
            title: title,
            notes: notes,
            start: start,
            end: end,
            timeZoneIdentifier: "Europe/Lisbon"
        )
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        return calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    private func month(_ date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        return calendar.component(.month, from: date)
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

    private var flightNotes: String {
        """
        ACTIVIDADE: LIS-CPH
        VOO TP754
        Saida: 15/07/2026 - 07:05
        Chegada: 15/07/2026 - 11:45
        Origem: LIS - Lisboa
        Destino: CPH - Copenhagen
        Matricula: CS-TVA - Airbus A320neo
        Pax: 154
        Radiacao Cosmica: 1,2
        Tripulacao:
        12345.6 CAB Joao Silva
        HOTEL: CPHRDS
        """
    }

    private var crossMonthFlightNotes: String {
        """
        ACTIVIDADE: 2CPH3101P
        VOO TP754
        Saida: 31/07/2026 - 23:00
        Chegada: 01/08/2026 - 02:30
        Origem: LIS - Lisboa
        Destino: CPH - Copenhagen
        HOTEL: CPHRDS
        VOO TP755
        Saida: 01/08/2026 - 06:00
        Chegada: 01/08/2026 - 08:30
        Origem: CPH - Copenhagen
        Destino: LIS - Lisboa
        """
    }

    private var yyzFlightNotes: String {
        """
        ACTIVIDADE: 1YYZ3001P
        VOO TP001
        Saida: 30/07/2026 - 10:40
        Chegada: 30/07/2026 - 14:00
        Origem: LIS - Lisboa
        Destino: YYZ - Toronto
        """
    }

    private var yyzInboundFlightNotes: String {
        """
        ACTIVIDADE: 1LIS3101P
        VOO TP002
        Saida: 31/07/2026 - 17:00
        Chegada: 01/08/2026 - 06:00
        Origem: YYZ - Toronto
        Destino: LIS - Lisboa
        """
    }
}
