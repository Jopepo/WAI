import Foundation

struct CalculationResult {
    let pickup: String
    let wakeup: String
    let transportTime: String
    let appliedRuleLabel: String?

    init(
        pickup: String,
        wakeup: String,
        transportTime: String,
        appliedRuleLabel: String? = nil
    ) {
        self.pickup = pickup
        self.wakeup = wakeup
        self.transportTime = transportTime
        self.appliedRuleLabel = appliedRuleLabel
    }
}

struct TimeCalculator {
    static let lisTimeZone = TimeZone(identifier: "Europe/Lisbon")!
    static let utcTimeZone = TimeZone(secondsFromGMT: 0)!

    static func calculate(
        selectedHour: Int,
        selectedMinute: Int,
        station: Station,
        selectedAlternative: String,
        defaultAlternativeTag: String,
        referenceDate: Date = Date()
    ) -> CalculationResult? {
        calculate(
            selectedHour: selectedHour,
            selectedMinute: selectedMinute,
            station: station,
            selectedAlternative: selectedAlternative,
            defaultAlternativeTag: defaultAlternativeTag,
            inputReference: .utc,
            etdDate: referenceDate,
            stationHolidays: []
        )
    }

    static func calculate(
        selectedHour: Int,
        selectedMinute: Int,
        station: Station,
        selectedAlternative: String,
        defaultAlternativeTag: String,
        inputReference: TimeInputReference,
        etdDate: Date,
        stationHolidays: [StationHoliday] = []
    ) -> CalculationResult? {
        guard let stationTimeZone = TimeZone(identifier: station.timeZone) else {
            return nil
        }

        let departureUTC = makeDepartureDate(
            hour: selectedHour,
            minute: selectedMinute,
            etdDate: etdDate,
            inputReference: inputReference,
            stationTimeZone: stationTimeZone
        )

        let departureLocalMinutes = minutesOfDay(for: departureUTC, in: stationTimeZone)
        let isWeekend = isWeekend(date: departureUTC, in: stationTimeZone)
        let isPublicHoliday = isPublicHoliday(
            date: departureUTC,
            in: stationTimeZone,
            stationHolidays: stationHolidays
        )

        if selectedAlternative != defaultAlternativeTag,
           let alternative = station.alternatives.first(where: { $0.label == selectedAlternative }) {
            return exactResult(
                departureUTC: departureUTC,
                transportMinutes: alternative.transportMinutes,
                station: station,
                stationTimeZone: stationTimeZone,
                appliedRuleLabel: alternative.label
            )
        }

        if let condition = matchingCondition(
            in: station.defaultRule.conditions,
            departureLocalMinutes: departureLocalMinutes,
            isWeekend: isWeekend,
            isPublicHoliday: isPublicHoliday
        ) {
            return exactResult(
                departureUTC: departureUTC,
                transportMinutes: condition.transportMinutes,
                station: station,
                stationTimeZone: stationTimeZone,
                appliedRuleLabel: condition.label
            )
        }

        switch station.defaultRule.type {
        case "fixed":
            guard let transport = station.defaultRule.transportMinutes else { return nil }
            return exactResult(
                departureUTC: departureUTC,
                transportMinutes: transport,
                station: station,
                stationTimeZone: stationTimeZone,
                appliedRuleLabel: station.defaultRule.label
            )

        case "timeDependent":
            guard let rules = station.defaultRule.rules else { return nil }

            for rule in rules {
                if rule.publicHolidaysOnly == true {
                    guard isPublicHoliday else { continue }
                }

                if rule.weekendsAndHolidaysOnly == true {
                    guard isWeekend || isPublicHoliday else { continue }
                }

                if rule.weekdaysOnly == true && (isWeekend || isPublicHoliday) {
                    continue
                }

                guard let fromLocal = rule.fromLocal,
                      let toLocal = rule.toLocal else {
                    return exactResult(
                        departureUTC: departureUTC,
                        transportMinutes: rule.transportMinutes,
                        station: station,
                        stationTimeZone: stationTimeZone,
                        appliedRuleLabel: rule.label
                    )
                }

                let from = parse(time: fromLocal)
                let to = parse(time: toLocal)

                if isTime(departureLocalMinutes, insideFrom: from, to: to) {
                    return exactResult(
                        departureUTC: departureUTC,
                        transportMinutes: rule.transportMinutes,
                        station: station,
                        stationTimeZone: stationTimeZone,
                        appliedRuleLabel: rule.label
                    )
                }
            }

            return nil

        case "range":
            guard let min = station.defaultRule.minTransportMinutes,
                  let max = station.defaultRule.maxTransportMinutes else {
                return nil
            }

            let pickupFromUTC = departureUTC.addingTimeInterval(TimeInterval(-(60 + max) * 60))
            let pickupToUTC = departureUTC.addingTimeInterval(TimeInterval(-(60 + min) * 60))
            let wakeupFromUTC = pickupFromUTC.addingTimeInterval(-60 * 60)
            let wakeupToUTC = pickupToUTC.addingTimeInterval(-60 * 60)

            return CalculationResult(
                pickup: formatRange(from: pickupFromUTC, to: pickupToUTC, station: station, stationTimeZone: stationTimeZone),
                wakeup: formatRange(from: wakeupFromUTC, to: wakeupToUTC, station: station, stationTimeZone: stationTimeZone),
                transportTime: "up to \(max) min",
                appliedRuleLabel: station.defaultRule.label
            )

        default:
            return nil
        }
    }

    static func localDepartureLabel(
        selectedHour: Int,
        selectedMinute: Int,
        station: Station,
        referenceDate: Date = Date()
    ) -> String {
        localDepartureLabel(
            selectedHour: selectedHour,
            selectedMinute: selectedMinute,
            station: station,
            inputReference: .utc,
            etdDate: referenceDate
        )
    }

    static func localDepartureLabel(
        selectedHour: Int,
        selectedMinute: Int,
        station: Station,
        inputReference: TimeInputReference,
        etdDate: Date
    ) -> String {
        guard let stationTimeZone = TimeZone(identifier: station.timeZone) else {
            return String(format: "%02d:%02d UTC", selectedHour, selectedMinute)
        }

        let departureUTC = makeDepartureDate(
            hour: selectedHour,
            minute: selectedMinute,
            etdDate: etdDate,
            inputReference: inputReference,
            stationTimeZone: stationTimeZone
        )

        return "\(format(departureUTC, in: stationTimeZone)) \(station.iata) / \(format(departureUTC, in: lisTimeZone)) LIS / \(format(departureUTC, in: utcTimeZone)) UTC"
    }

    private static func exactResult(
        departureUTC: Date,
        transportMinutes: Int,
        station: Station,
        stationTimeZone: TimeZone,
        appliedRuleLabel: String?
    ) -> CalculationResult {
        let pickupUTC = departureUTC.addingTimeInterval(TimeInterval(-(60 + transportMinutes) * 60))
        let wakeupUTC = pickupUTC.addingTimeInterval(-60 * 60)

        return CalculationResult(
            pickup: formatDualTime(pickupUTC, station: station, stationTimeZone: stationTimeZone),
            wakeup: formatDualTime(wakeupUTC, station: station, stationTimeZone: stationTimeZone),
            transportTime: "\(transportMinutes) min",
            appliedRuleLabel: appliedRuleLabel
        )
    }

    private static func makeDepartureDate(
        hour: Int,
        minute: Int,
        etdDate: Date,
        inputReference: TimeInputReference,
        stationTimeZone: TimeZone
    ) -> Date {
        let inputTimeZone: TimeZone

        switch inputReference {
        case .utc:
            inputTimeZone = utcTimeZone
        case .stationLocal:
            inputTimeZone = stationTimeZone
        case .lisbon:
            inputTimeZone = lisTimeZone
        }

        var displayCalendar = Calendar(identifier: .gregorian)
        displayCalendar.timeZone = Calendar.current.timeZone

        let dateComponents = displayCalendar.dateComponents([.year, .month, .day], from: etdDate)

        var inputCalendar = Calendar(identifier: .gregorian)
        inputCalendar.timeZone = inputTimeZone

        return inputCalendar.date(from: DateComponents(
            timeZone: inputTimeZone,
            year: dateComponents.year,
            month: dateComponents.month,
            day: dateComponents.day,
            hour: hour,
            minute: minute
        )) ?? etdDate
    }

    private static func makeUTCDate(hour: Int, minute: Int, referenceDate: Date) -> Date {
        makeDepartureDate(
            hour: hour,
            minute: minute,
            etdDate: referenceDate,
            inputReference: .utc,
            stationTimeZone: utcTimeZone
        )
    }

    private static func minutesOfDay(for date: Date, in timeZone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)

        return hour * 60 + minute
    }

    private static func isWeekend(date: Date, in timeZone: TimeZone) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let weekday = calendar.component(.weekday, from: date)
        return weekday == 1 || weekday == 7
    }

    private static func isPublicHoliday(
        date: Date,
        in timeZone: TimeZone,
        stationHolidays: [StationHoliday]
    ) -> Bool {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        let localDate = formatter.string(from: date)
        return stationHolidays.contains { $0.date == localDate }
    }

    private static func matchingCondition(
        in conditions: [TransportCondition]?,
        departureLocalMinutes: Int,
        isWeekend: Bool,
        isPublicHoliday: Bool
    ) -> TransportCondition? {
        guard let conditions else { return nil }

        for condition in conditions {
            if condition.appliesOnPublicHolidays == true && !isPublicHoliday {
                continue
            }

            if condition.appliesOnWeekends == true && !isWeekend {
                continue
            }

            if condition.appliesOnWeekdays == true && (isWeekend || isPublicHoliday) {
                continue
            }

            if let fromLocal = condition.fromLocal,
               let toLocal = condition.toLocal {
                let from = parse(time: fromLocal)
                let to = parse(time: toLocal)

                guard isTime(departureLocalMinutes, insideFrom: from, to: to) else {
                    continue
                }
            }

            return condition
        }

        return nil
    }

    private static func isTime(_ time: Int, insideFrom from: Int, to: Int) -> Bool {
        if from <= to {
            return time >= from && time <= to
        } else {
            return time >= from || time <= to
        }
    }

    private static func parse(time: String) -> Int {
        let parts = time.split(separator: ":")
        let hours = Int(parts.first ?? "0") ?? 0
        let minutes = Int(parts.dropFirst().first ?? "0") ?? 0
        return hours * 60 + minutes
    }

    private static func formatDualTime(
        _ date: Date,
        station: Station,
        stationTimeZone: TimeZone
    ) -> String {
        "\(format(date, in: stationTimeZone)) \(station.iata) (\(format(date, in: lisTimeZone)) LIS)"
    }

    private static func formatRange(
        from: Date,
        to: Date,
        station: Station,
        stationTimeZone: TimeZone
    ) -> String {
        let stationRange = "\(format(from, in: stationTimeZone)) - \(format(to, in: stationTimeZone)) \(station.iata)"
        let lisRange = "\(format(from, in: lisTimeZone)) - \(format(to, in: lisTimeZone)) LIS"
        return "\(stationRange) (\(lisRange))"
    }

    private static func format(_ date: Date, in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
