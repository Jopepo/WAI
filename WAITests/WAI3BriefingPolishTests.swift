import Foundation
import Testing
@testable import WAI

struct WAI3RoutineTimeResolverTests {
    @Test func resolvesBothTimesOnTheReportDay() throws {
        let report = try date(2026, 7, 18, 8, 0)
        let result = try #require(
            WAI3RoutineTimeResolver.resolvedPair(
                wakeupClock: try date(2026, 7, 18, 5, 30),
                pickupClock: try date(2026, 7, 18, 6, 30),
                report: report,
                timeZoneIdentifier: "Europe/Lisbon"
            )
        )

        let expectedWakeup = try date(2026, 7, 18, 5, 30)
        let expectedPickup = try date(2026, 7, 18, 6, 30)
        #expect(result.wakeup == expectedWakeup)
        #expect(result.pickup == expectedPickup)
    }

    @Test func resolvesWakeupAcrossMidnightWithoutAVisibleDateInput() throws {
        let report = try date(2026, 7, 18, 1, 30)
        let result = try #require(
            WAI3RoutineTimeResolver.resolvedPair(
                wakeupClock: try date(2026, 7, 18, 23, 15),
                pickupClock: try date(2026, 7, 18, 0, 15),
                report: report,
                timeZoneIdentifier: "Europe/Lisbon"
            )
        )

        let expectedWakeup = try date(2026, 7, 17, 23, 15)
        let expectedPickup = try date(2026, 7, 18, 0, 15)
        #expect(result.wakeup == expectedWakeup)
        #expect(result.pickup == expectedPickup)
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int
    ) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(
            TimeZone(identifier: "Europe/Lisbon")
        )
        return try #require(
            calendar.date(
                from: DateComponents(
                    year: year,
                    month: month,
                    day: day,
                    hour: hour,
                    minute: minute
                )
            )
        )
    }
}

struct AviationWeatherReportTests {
    @Test func decodesCurrentMetarFieldsWithoutDependingOnEveryAPIField() throws {
        let data = Data(
            """
            [{
              "icaoId":"LPPT",
              "rawOb":"LPPT 170000Z 34008KT 9999 FEW020 23/15 Q1017",
              "obsTime":1784246400,
              "temp":23,
              "dewp":15,
              "wdir":340,
              "wspd":8,
              "visib":"6+",
              "altim":1017,
              "fltCat":"VFR",
              "unknownFutureField":true
            }]
            """.utf8
        )

        let report = try #require(
            JSONDecoder().decode([AviationWeatherReport].self, from: data).first
        )
        #expect(report.icaoID == "LPPT")
        #expect(report.temperatureCelsius == 23)
        #expect(report.windDirectionDegrees == 340)
        #expect(report.windSpeedKnots == 8)
        #expect(report.altimeterHPa == 1017)
        #expect(report.flightCategory == "VFR")
        #expect(report.observationTime == Date(timeIntervalSince1970: 1784246400))
    }

    @Test func acceptsNumericFieldsEncodedAsStrings() throws {
        let data = Data(
            #"[{"icaoId":"EKCH","rawOb":"EKCH TEST","temp":"18.5","wspd":"12"}]"#.utf8
        )

        let report = try #require(
            JSONDecoder().decode([AviationWeatherReport].self, from: data).first
        )
        #expect(report.temperatureCelsius == 18.5)
        #expect(report.windSpeedKnots == 12)
    }
}
