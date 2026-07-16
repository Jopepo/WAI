import Foundation
import Testing
@testable import WAI

struct TimeCalculatorRegressionTests {
    private let defaultAlternativeTag = "__DEFAULT__"

    @Test func rev73RulesRemainCalculableAcrossTheirFullSurface() throws {
        let document = try transportDocument()

        #expect(document.source?.revision == "REV73")
        #expect(document.stations.count == 61)

        let representativeDates = [
            dateAnchor(year: 2026, month: 7, day: 7),
            dateAnchor(year: 2026, month: 7, day: 11)
        ]

        for station in document.stations {
            let minuteSamples = station.defaultRule.type == "timeDependent"
                ? Array(0..<(24 * 60))
                : [0, 359, 360, 539, 540, 1_259, 1_260, 1_439]

            for date in representativeDates {
                for minuteOfDay in minuteSamples {
                    let details = TimeCalculator.calculateDetails(
                        selectedHour: minuteOfDay / 60,
                        selectedMinute: minuteOfDay % 60,
                        station: station,
                        selectedAlternative: defaultAlternativeTag,
                        defaultAlternativeTag: defaultAlternativeTag,
                        inputReference: .utc,
                        etdDate: date,
                        stationHolidays: station.holidays ?? []
                    )

                    let value = try #require(details)
                    #expect(value.report <= value.departure)
                    #expect(value.pickup.earliest <= value.pickup.latest)
                    #expect(value.wakeup.earliest <= value.wakeup.latest)
                    #expect(
                        value.wakeup.earliest
                            == value.pickup.earliest.addingTimeInterval(-3_600)
                    )
                    #expect(
                        value.wakeup.latest
                            == value.pickup.latest.addingTimeInterval(-3_600)
                    )
                    #expect(
                        value.minimumTransportMinutes
                            <= value.maximumTransportMinutes
                    )
                }
            }

            for alternative in station.alternatives {
                let value = try #require(TimeCalculator.calculateDetails(
                    selectedHour: 12,
                    selectedMinute: 0,
                    station: station,
                    selectedAlternative: alternative.label,
                    defaultAlternativeTag: defaultAlternativeTag,
                    inputReference: .utc,
                    etdDate: representativeDates[0],
                    stationHolidays: station.holidays ?? []
                ))
                #expect(value.minimumTransportMinutes == alternative.transportMinutes)
                #expect(value.maximumTransportMinutes == alternative.transportMinutes)
                #expect(value.appliedRuleLabel == alternative.label)
            }
        }
    }

    @Test func rev73TimeDependentBoundariesAreInclusive() throws {
        let document = try transportDocument()
        let cases: [(
            station: String,
            hour: Int,
            minute: Int,
            transport: Int,
            label: String
        )] = [
            ("EWR", 6, 0, 70, "Night 21:00–06:00"),
            ("EWR", 6, 1, 90, "Standard"),
            ("EWR", 20, 59, 90, "Standard"),
            ("EWR", 21, 0, 70, "Night 21:00–06:00"),
            ("YYZ", 6, 0, 75, "Night STD"),
            ("YYZ", 6, 1, 110, "Standard"),
            ("YYZ", 19, 59, 110, "Standard"),
            ("YYZ", 20, 0, 75, "Night STD")
        ]

        for item in cases {
            let station = try station(item.station, in: document)
            let departure = try localDate(
                year: 2026,
                month: 7,
                day: 7,
                hour: item.hour,
                minute: item.minute,
                timeZoneIdentifier: station.timeZone
            )
            let details = try #require(TimeCalculator.calculateDetails(
                departure: departure,
                station: station,
                selectedAlternative: defaultAlternativeTag,
                defaultAlternativeTag: defaultAlternativeTag,
                stationHolidays: station.holidays ?? []
            ))

            #expect(details.maximumTransportMinutes == item.transport)
            #expect(details.appliedRuleLabel == item.label)
        }
    }

    @Test func portoConditionsUseLocalDateAndTime() throws {
        let document = try transportDocument()
        let opo = try station("OPO", in: document)
        let cases: [(
            year: Int,
            month: Int,
            day: Int,
            hour: Int,
            minute: Int,
            transport: Int,
            label: String
        )] = [
            (2026, 7, 7, 9, 0, 45, "Weekday 09:00–21:00"),
            (2026, 7, 7, 8, 59, 30, "Night 21:01–08:59"),
            (2026, 7, 11, 12, 0, 30, "Weekend"),
            (2026, 6, 10, 12, 0, 30, "Public holiday")
        ]

        for item in cases {
            let departure = try localDate(
                year: item.year,
                month: item.month,
                day: item.day,
                hour: item.hour,
                minute: item.minute,
                timeZoneIdentifier: opo.timeZone
            )
            let details = try #require(TimeCalculator.calculateDetails(
                departure: departure,
                station: opo,
                selectedAlternative: defaultAlternativeTag,
                defaultAlternativeTag: defaultAlternativeTag,
                stationHolidays: opo.holidays ?? []
            ))

            #expect(details.maximumTransportMinutes == item.transport)
            #expect(details.appliedRuleLabel == item.label)
        }
    }

    @Test func alternativeOverridesDefaultAndConditionalRules() throws {
        let document = try transportDocument()
        let gru = try station("GRU", in: document)
        let alternative = try #require(gru.alternatives.first)
        let holidayDeparture = try localDate(
            year: 2026,
            month: 4,
            day: 21,
            hour: 10,
            minute: 0,
            timeZoneIdentifier: gru.timeZone
        )

        let details = try #require(TimeCalculator.calculateDetails(
            departure: holidayDeparture,
            station: gru,
            selectedAlternative: alternative.label,
            defaultAlternativeTag: defaultAlternativeTag,
            stationHolidays: gru.holidays ?? []
        ))

        #expect(details.maximumTransportMinutes == 100)
        #expect(details.appliedRuleLabel == "TP88 / TP94")
    }

    @Test func inputReferencesResolveToTheSameDepartureInstant() throws {
        let document = try transportDocument()
        let cph = try station("CPH", in: document)
        let date = dateAnchor(year: 2026, month: 7, day: 7)
        let inputs: [(hour: Int, reference: TimeInputReference)] = [
            (8, .utc),
            (9, .lisbon),
            (10, .stationLocal)
        ]

        let details = try inputs.map { input in
            try #require(TimeCalculator.calculateDetails(
                selectedHour: input.hour,
                selectedMinute: 0,
                station: cph,
                selectedAlternative: defaultAlternativeTag,
                defaultAlternativeTag: defaultAlternativeTag,
                inputReference: input.reference,
                etdDate: date
            ))
        }
        #expect(Set(details.map(\.departure)).count == 1)

        for input in inputs {
            let result = try #require(TimeCalculator.calculate(
                selectedHour: input.hour,
                selectedMinute: 0,
                station: cph,
                selectedAlternative: defaultAlternativeTag,
                defaultAlternativeTag: defaultAlternativeTag,
                inputReference: input.reference,
                etdDate: date
            ))
            #expect(result.pickup == "08:25 CPH (07:25 LIS)")
            #expect(result.wakeup == "07:25 CPH (06:25 LIS)")
        }

        #expect(TimeCalculator.localDepartureLabel(
            selectedHour: 10,
            selectedMinute: 0,
            station: cph,
            inputReference: .stationLocal,
            etdDate: date
        ) == "10:00 CPH / 09:00 LIS / 08:00 UTC")
    }

    @Test func rosterReportTimeControlsPickupInsteadOfDefaultSignOn() throws {
        let document = try transportDocument()
        let cph = try station("CPH", in: document)
        let departure = try localDate(
            year: 2026,
            month: 7,
            day: 7,
            hour: 10,
            minute: 0,
            timeZoneIdentifier: cph.timeZone
        )
        let report = try localDate(
            year: 2026,
            month: 7,
            day: 7,
            hour: 8,
            minute: 30,
            timeZoneIdentifier: cph.timeZone
        )
        let expectedPickup = try localDate(
            year: 2026,
            month: 7,
            day: 7,
            hour: 7,
            minute: 55,
            timeZoneIdentifier: cph.timeZone
        )

        let details = try #require(TimeCalculator.calculateDetails(
            departure: departure,
            reportTime: report,
            station: cph,
            selectedAlternative: defaultAlternativeTag,
            defaultAlternativeTag: defaultAlternativeTag
        ))

        #expect(details.report == report)
        #expect(details.pickup.earliest == expectedPickup)
        #expect(
            details.wakeup.earliest
                == expectedPickup.addingTimeInterval(-3_600)
        )

        #expect(TimeCalculator.calculateDetails(
            departure: departure,
            reportTime: departure.addingTimeInterval(60),
            station: cph,
            selectedAlternative: defaultAlternativeTag,
            defaultAlternativeTag: defaultAlternativeTag
        ) == nil)
    }

    @Test func ambiguousOrNonexistentLocalInputFailsClosed() throws {
        let document = try transportDocument()
        let lis = try station("LIS", in: document)
        let spring = dateAnchor(year: 2026, month: 3, day: 29)
        let autumn = dateAnchor(year: 2026, month: 10, day: 25)

        for date in [spring, autumn] {
            #expect(TimeCalculator.calculateDetails(
                selectedHour: 1,
                selectedMinute: 30,
                station: lis,
                selectedAlternative: defaultAlternativeTag,
                defaultAlternativeTag: defaultAlternativeTag,
                inputReference: .stationLocal,
                etdDate: date
            ) == nil)
            #expect(TimeCalculator.calculateDetails(
                selectedHour: 1,
                selectedMinute: 30,
                station: lis,
                selectedAlternative: defaultAlternativeTag,
                defaultAlternativeTag: defaultAlternativeTag,
                inputReference: .lisbon,
                etdDate: date
            ) == nil)
        }

        #expect(TimeCalculator.localDepartureLabel(
            selectedHour: 1,
            selectedMinute: 30,
            station: lis,
            inputReference: .stationLocal,
            etdDate: spring
        ) == "Invalid local time")

        #expect(TimeCalculator.calculateDetails(
            selectedHour: 1,
            selectedMinute: 30,
            station: lis,
            selectedAlternative: defaultAlternativeTag,
            defaultAlternativeTag: defaultAlternativeTag,
            inputReference: .utc,
            etdDate: spring
        ) != nil)
        #expect(TimeCalculator.calculateDetails(
            selectedHour: 24,
            selectedMinute: 0,
            station: lis,
            selectedAlternative: defaultAlternativeTag,
            defaultAlternativeTag: defaultAlternativeTag,
            inputReference: .utc,
            etdDate: spring
        ) == nil)
    }

    private func transportDocument() throws -> StationData {
        let url = try #require(Bundle.main.url(
            forResource: "wai_transport_rules_current",
            withExtension: "json"
        ))
        return try JSONDecoder().decode(
            StationData.self,
            from: Data(contentsOf: url)
        )
    }

    private func station(_ iata: String, in document: StationData) throws -> Station {
        try #require(document.stations.first { $0.iata == iata })
    }

    private func dateAnchor(year: Int, month: Int, day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: 12
        )) ?? Date(timeIntervalSince1970: 0)
    }

    private func localDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        timeZoneIdentifier: String
    ) throws -> Date {
        let timeZone = try #require(TimeZone(identifier: timeZoneIdentifier))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return try #require(calendar.date(from: DateComponents(
            timeZone: timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )))
    }
}
