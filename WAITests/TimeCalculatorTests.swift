import Foundation
import Testing
@testable import WAI

struct TimeCalculatorTests {
    private let defaultAlternativeTag = "__DEFAULT__"

    @Test func accFixedRule() throws {
        let result = try #require(calculate(
            station: Fixtures.acc,
            hour: 10,
            minute: 0,
            date: utcDate(year: 2026, month: 7, day: 7)
        ))

        #expect(result.transportTime == "30 min")
        #expect(result.pickup == "08:30 ACC (09:30 LIS)")
        #expect(result.wakeup == "07:30 ACC (08:30 LIS)")
        #expect(result.appliedRuleLabel == nil)
    }

    @Test func ewrNightRuleCrossingMidnight() throws {
        let result = try #require(calculate(
            station: Fixtures.ewr,
            hour: 2,
            minute: 0,
            date: utcDate(year: 2026, month: 7, day: 7)
        ))

        #expect(result.transportTime == "70 min")
        #expect(result.pickup == "19:50 EWR (00:50 LIS)")
        #expect(result.wakeup == "18:50 EWR (23:50 LIS)")
        #expect(result.appliedRuleLabel == "Night 21:00–06:00")
    }

    @Test func gigRangeRule() throws {
        let result = try #require(calculate(
            station: Fixtures.gig,
            hour: 12,
            minute: 0,
            date: utcDate(year: 2026, month: 7, day: 7)
        ))

        #expect(result.transportTime == "up to 110 min")
        #expect(result.pickup == "06:10 - 08:00 GIG (10:10 - 12:00 LIS)")
        #expect(result.wakeup == "05:10 - 07:00 GIG (09:10 - 11:00 LIS)")
        #expect(result.appliedRuleLabel == nil)
    }

    @Test func gruWeekdayRule() throws {
        let result = try #require(calculate(
            station: Fixtures.gru,
            hour: 15,
            minute: 0,
            date: utcDate(year: 2026, month: 7, day: 7),
            stationHolidays: Fixtures.gru.holidays ?? []
        ))

        #expect(result.transportTime == "90 min")
        #expect(result.pickup == "09:30 GRU (13:30 LIS)")
        #expect(result.wakeup == "08:30 GRU (12:30 LIS)")
        #expect(result.appliedRuleLabel == "Weekday")
    }

    @Test func gruWeekendRule() throws {
        let result = try #require(calculate(
            station: Fixtures.gru,
            hour: 15,
            minute: 0,
            date: utcDate(year: 2026, month: 7, day: 11),
            stationHolidays: Fixtures.gru.holidays ?? []
        ))

        #expect(result.transportTime == "80 min")
        #expect(result.pickup == "09:40 GRU (13:40 LIS)")
        #expect(result.wakeup == "08:40 GRU (12:40 LIS)")
        #expect(result.appliedRuleLabel == "Weekend")
    }

    @Test func gruPublicHolidayRule() throws {
        let result = try #require(calculate(
            station: Fixtures.gru,
            hour: 15,
            minute: 0,
            date: utcDate(year: 2026, month: 4, day: 21),
            stationHolidays: Fixtures.gru.holidays ?? []
        ))

        #expect(result.transportTime == "80 min")
        #expect(result.pickup == "09:40 GRU (13:40 LIS)")
        #expect(result.wakeup == "08:40 GRU (12:40 LIS)")
        #expect(result.appliedRuleLabel == "Public holiday")
    }

    private func calculate(
        station: Station,
        hour: Int,
        minute: Int,
        date: Date,
        selectedAlternative: String? = nil,
        stationHolidays: [StationHoliday] = []
    ) -> CalculationResult? {
        TimeCalculator.calculate(
            selectedHour: hour,
            selectedMinute: minute,
            station: station,
            selectedAlternative: selectedAlternative ?? defaultAlternativeTag,
            defaultAlternativeTag: defaultAlternativeTag,
            inputReference: .utc,
            etdDate: date,
            stationHolidays: stationHolidays
        )
    }

    private func utcDate(year: Int, month: Int, day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!

        return calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: 12,
            minute: 0
        ))!
    }
}

private enum Fixtures {
    static let acc = Station(
        iata: "ACC",
        icao: "DGAA",
        city: "Accra",
        country: "Ghana",
        timeZone: "Africa/Accra",
        standardUtcOffset: "+00:00",
        summerUtcOffset: "+00:00",
        defaultRule: TransportRule(
            type: "fixed",
            label: nil,
            transportMinutes: 30,
            minTransportMinutes: nil,
            maxTransportMinutes: nil,
            rules: nil,
            conditions: nil
        ),
        alternatives: [],
        holidays: nil
    )

    static let ewr = Station(
        iata: "EWR",
        icao: "KEWR",
        city: "Newark",
        country: "USA",
        timeZone: "America/New_York",
        standardUtcOffset: "-05:00",
        summerUtcOffset: "-04:00",
        defaultRule: TransportRule(
            type: "timeDependent",
            label: nil,
            transportMinutes: nil,
            minTransportMinutes: nil,
            maxTransportMinutes: nil,
            rules: [
                TimeRule(
                    label: "Night 21:00–06:00",
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
            ],
            conditions: nil
        ),
        alternatives: [],
        holidays: nil
    )

    static let gig = Station(
        iata: "GIG",
        icao: "SBGL",
        city: "Rio de Janeiro",
        country: "Brazil",
        timeZone: "America/Sao_Paulo",
        standardUtcOffset: "-03:00",
        summerUtcOffset: "-03:00",
        defaultRule: TransportRule(
            type: "range",
            label: nil,
            transportMinutes: nil,
            minTransportMinutes: 0,
            maxTransportMinutes: 110,
            rules: nil,
            conditions: nil
        ),
        alternatives: [],
        holidays: nil
    )

    static let gru = Station(
        iata: "GRU",
        icao: "SBGR",
        city: "São Paulo",
        country: "Brazil",
        timeZone: "America/Sao_Paulo",
        standardUtcOffset: "-03:00",
        summerUtcOffset: "-03:00",
        defaultRule: TransportRule(
            type: "fixed",
            label: "Weekday",
            transportMinutes: 90,
            minTransportMinutes: nil,
            maxTransportMinutes: nil,
            rules: nil,
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
            ]
        ),
        alternatives: [
            TransportAlternative(label: "TP88 / TP94", transportMinutes: 100),
            TransportAlternative(label: "Specific locally coordinated Hotel-Airport transfer", transportMinutes: 100)
        ],
        holidays: [
            StationHoliday(date: "2026-04-21", name: "Tiradentes Day")
        ]
    )
}
