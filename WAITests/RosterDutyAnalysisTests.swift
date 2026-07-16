import Foundation
import Testing
@testable import WAI

struct RosterDutyAnalysisTests {
    @Test func resolvedLegRosterSpanAndIntervalUseAbsoluteInstants() throws {
        let first = flightDuty(
            id: "first",
            start: utcDate(2026, 7, 15, 5, 0),
            end: utcDate(2026, 7, 15, 10, 15),
            legs: [
                leg(
                    id: "lis-cph",
                    origin: "LIS",
                    destination: "CPH",
                    departure: resolvedLocal(
                        "Europe/Lisbon",
                        2026, 7, 15, 7, 0
                    ),
                    arrival: resolvedLocal(
                        "Europe/Copenhagen",
                        2026, 7, 15, 11, 45
                    )
                )
            ]
        )
        let second = flightDuty(
            id: "second",
            start: utcDate(2026, 7, 17, 5, 0),
            end: utcDate(2026, 7, 17, 10, 45),
            legs: [
                leg(
                    id: "lis-mad",
                    origin: "LIS",
                    destination: "MAD",
                    departure: resolvedUTC(2026, 7, 17, 6, 0),
                    arrival: resolvedUTC(2026, 7, 17, 7, 15)
                )
            ]
        )

        let analyses = RosterDutyAnalyzer.analyze([second, first])
        let firstAnalysis = try #require(
            analyses.first { $0.dutyID == "first" }
        )
        let secondAnalysis = try #require(
            analyses.first { $0.dutyID == "second" }
        )

        #expect(firstAnalysis.rosterSpanMinutes == 315)
        #expect(firstAnalysis.legs.first?.blockMinutes == 225)
        #expect(secondAnalysis.intervalBefore == .measured(minutes: 2_565))
    }

    @Test func unresolvedStationTimeDoesNotInventBlockDuration() throws {
        let unresolved = RosterLocalDateTime(
            year: 2026,
            month: 7,
            day: 15,
            hour: 7,
            minute: 0,
            timeZoneIdentifier: nil,
            instant: nil
        )
        let item = flightDuty(
            id: "unresolved",
            start: utcDate(2026, 7, 15, 5, 0),
            end: utcDate(2026, 7, 15, 10, 0),
            legs: [
                leg(
                    id: "unknown-leg",
                    origin: "LIS",
                    destination: "OXB",
                    departure: unresolved,
                    arrival: unresolved
                )
            ]
        )

        let analysis = try #require(
            RosterDutyAnalyzer.analyze([item]).first
        )

        #expect(analysis.legs.first?.blockMinutes == nil)
        #expect(analysis.unresolvedLegCount == 1)
    }

    @Test func overlappingFlightEventsAreFlaggedAsDataConflict() throws {
        let first = flightDuty(
            id: "first",
            start: utcDate(2026, 7, 15, 5, 0),
            end: utcDate(2026, 7, 15, 10, 0),
            legs: [simpleLeg(id: "first-leg", hour: 6)]
        )
        let second = flightDuty(
            id: "second",
            start: utcDate(2026, 7, 15, 9, 30),
            end: utcDate(2026, 7, 15, 11, 0),
            legs: [simpleLeg(id: "second-leg", hour: 10)]
        )

        let analysis = try #require(
            RosterDutyAnalyzer.analyze([first, second]).last
        )

        #expect(analysis.intervalBefore == .overlap(minutes: 30))
    }

    @Test func knownDaysOffDoNotHideMeasuredFlightInterval() throws {
        let first = flightDuty(
            id: "first",
            start: utcDate(2026, 7, 1, 5, 0),
            end: utcDate(2026, 7, 1, 10, 0),
            legs: [simpleLeg(id: "first-leg", hour: 6)]
        )
        let dayOff = activity(
            id: "off",
            code: "DFD",
            start: utcDate(2026, 7, 2, 0, 0),
            end: utcDate(2026, 7, 3, 0, 0)
        )
        let second = flightDuty(
            id: "second",
            start: utcDate(2026, 7, 4, 5, 0),
            end: utcDate(2026, 7, 4, 10, 0),
            legs: [simpleLeg(id: "second-leg", hour: 6, day: 4)]
        )

        let result = try #require(
            RosterDutyAnalyzer.analyze([first, dayOff, second])
                .first { $0.dutyID == "second" }
        )

        #expect(result.intervalBefore == .measured(minutes: 4_020))
    }

    @Test func unknownInterveningActivityPreventsRestInference() throws {
        let first = flightDuty(
            id: "first",
            start: utcDate(2026, 7, 1, 5, 0),
            end: utcDate(2026, 7, 1, 10, 0),
            legs: [simpleLeg(id: "first-leg", hour: 6)]
        )
        let training = activity(
            id: "training",
            code: "SIM",
            start: utcDate(2026, 7, 2, 8, 0),
            end: utcDate(2026, 7, 2, 12, 0)
        )
        let second = flightDuty(
            id: "second",
            start: utcDate(2026, 7, 4, 5, 0),
            end: utcDate(2026, 7, 4, 10, 0),
            legs: [simpleLeg(id: "second-leg", hour: 6, day: 4)]
        )

        let result = try #require(
            RosterDutyAnalyzer.analyze([first, training, second])
                .first { $0.dutyID == "second" }
        )

        #expect(result.intervalBefore == .interruptedByActivity)
    }

    @Test func hotelRotationIsSplitIntoObjectiveFlightPeriods() throws {
        let rotation = flightDuty(
            id: "rotation",
            start: utcDate(2026, 7, 6, 13, 5),
            end: utcDate(2026, 7, 8, 8, 20),
            hotelCode: "MXPHIL",
            legs: [
                leg(
                    id: "outbound",
                    origin: "LIS",
                    destination: "MXP",
                    departure: resolvedUTC(2026, 7, 6, 14, 5),
                    arrival: resolvedUTC(2026, 7, 6, 17, 30)
                ),
                leg(
                    id: "inbound",
                    origin: "MXP",
                    destination: "LIS",
                    departure: resolvedUTC(2026, 7, 8, 5, 50),
                    arrival: resolvedUTC(2026, 7, 8, 7, 50)
                )
            ]
        )

        let analysis = try #require(
            RosterDutyAnalyzer.analyze([rotation]).first
        )

        #expect(analysis.rosterSpanMinutes == 2_595)
        #expect(analysis.flightPeriods.count == 2)
        #expect(analysis.flightPeriods[0].resolvedBlockMinutes == 205)
        #expect(
            analysis.flightPeriods[0].groundToNextPeriodMinutes == 2_180
        )
        #expect(analysis.flightPeriods[1].resolvedBlockMinutes == 120)
    }

    @Test func periodSummaryAggregatesOnlyObjectiveValues() {
        let first = flightDuty(
            id: "first",
            start: utcDate(2026, 7, 1, 5, 0),
            end: utcDate(2026, 7, 1, 10, 0),
            legs: [simpleLeg(id: "first-leg", hour: 6)]
        )
        let second = flightDuty(
            id: "second",
            start: utcDate(2026, 7, 2, 5, 0),
            end: utcDate(2026, 7, 2, 10, 0),
            legs: [simpleLeg(id: "second-leg", hour: 6, day: 2)]
        )

        let summary = RosterPeriodAnalyzer.summarize([first, second])

        #expect(summary.flightRotationCount == 2)
        #expect(summary.flightPeriodCount == 2)
        #expect(summary.legCount == 2)
        #expect(summary.resolvedBlockMinutes == 120)
        #expect(summary.unresolvedLegCount == 0)
        #expect(summary.measuredIntervalCount == 1)
        #expect(summary.shortestMeasuredIntervalMinutes == 1_140)
        #expect(summary.overlapCount == 0)
    }

    private func flightDuty(
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

    private func activity(
        id: String,
        code: String,
        start: Date,
        end: Date
    ) -> RosterDuty {
        RosterDuty(
            id: id,
            activityCode: code,
            start: start,
            end: end,
            timeZoneIdentifier: "Europe/Lisbon",
            kind: .activity,
            hotelCode: nil,
            legs: []
        )
    }

    private func simpleLeg(
        id: String,
        hour: Int,
        day: Int = 1
    ) -> RosterLeg {
        leg(
            id: id,
            origin: "LIS",
            destination: "MAD",
            departure: resolvedUTC(2026, 7, day, hour, 0),
            arrival: resolvedUTC(2026, 7, day, hour + 1, 0)
        )
    }

    private func leg(
        id: String,
        origin: String,
        destination: String,
        departure: RosterLocalDateTime,
        arrival: RosterLocalDateTime
    ) -> RosterLeg {
        RosterLeg(
            id: id,
            flightNumber: "TP100",
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

    private func resolvedUTC(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int
    ) -> RosterLocalDateTime {
        resolvedLocal("UTC", year, month, day, hour, minute)
    }

    private func resolvedLocal(
        _ timeZoneIdentifier: String,
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int
    ) -> RosterLocalDateTime {
        let instant = date(
            timeZoneIdentifier,
            year, month, day, hour, minute
        )
        return RosterLocalDateTime(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            timeZoneIdentifier: timeZoneIdentifier,
            instant: instant
        )
    }

    private func utcDate(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int
    ) -> Date {
        date("UTC", year, month, day, hour, minute)
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
}
