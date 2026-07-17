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

struct TimeCalculationWindow: Equatable, Sendable {
    let earliest: Date
    let latest: Date

    var isExact: Bool {
        earliest == latest
    }
}

struct TimeCalculationDetails: Equatable, Sendable {
    let departure: Date
    let report: Date
    let pickup: TimeCalculationWindow
    let wakeup: TimeCalculationWindow
    let minimumTransportMinutes: Int
    let maximumTransportMinutes: Int
    let usesTransportRange: Bool
    let appliedRuleLabel: String?
}

struct TransportMinutesWindow: Equatable, Sendable {
    let minimum: Int
    let maximum: Int

    var isExact: Bool { minimum == maximum }
}

struct TimeCalculator {
    static let lisTimeZone = TimeZone(identifier: "Europe/Lisbon")!
    static let utcTimeZone = TimeZone(identifier: "GMT")!

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
        guard let stationTimeZone = TimeZone(identifier: station.timeZone),
              let details = calculateDetails(
                selectedHour: selectedHour,
                selectedMinute: selectedMinute,
                station: station,
                selectedAlternative: selectedAlternative,
                defaultAlternativeTag: defaultAlternativeTag,
                inputReference: inputReference,
                etdDate: etdDate,
                stationHolidays: stationHolidays
              ) else {
            return nil
        }

        return formattedResult(
            details,
            station: station,
            stationTimeZone: stationTimeZone
        )
    }

    static func calculateDetails(
        selectedHour: Int,
        selectedMinute: Int,
        station: Station,
        selectedAlternative: String,
        defaultAlternativeTag: String,
        inputReference: TimeInputReference,
        etdDate: Date,
        stationHolidays: [StationHoliday] = []
    ) -> TimeCalculationDetails? {
        guard let stationTimeZone = TimeZone(identifier: station.timeZone) else {
            return nil
        }

        guard let departure = makeDepartureDate(
            hour: selectedHour,
            minute: selectedMinute,
            etdDate: etdDate,
            inputReference: inputReference,
            stationTimeZone: stationTimeZone
        ) else {
            return nil
        }

        return calculateDetails(
            departure: departure,
            station: station,
            selectedAlternative: selectedAlternative,
            defaultAlternativeTag: defaultAlternativeTag,
            stationHolidays: stationHolidays
        )
    }

    static func defaultTransportMinutes(
        departure: Date,
        station: Station,
        stationHolidays: [StationHoliday] = []
    ) -> TransportMinutesWindow? {
        guard let stationTimeZone = TimeZone(identifier: station.timeZone),
              let selection = transportSelection(
                departure: departure,
                station: station,
                stationTimeZone: stationTimeZone,
                selectedAlternative: "__WAI_DEFAULT__",
                defaultAlternativeTag: "__WAI_DEFAULT__",
                stationHolidays: stationHolidays
              ) else {
            return nil
        }
        switch selection {
        case .exact(let minutes, _):
            return TransportMinutesWindow(
                minimum: minutes,
                maximum: minutes
            )
        case .range(let minimum, let maximum, _):
            return TransportMinutesWindow(
                minimum: minimum,
                maximum: maximum
            )
        }
    }

    static func calculateDetails(
        departure: Date,
        reportTime: Date? = nil,
        station: Station,
        selectedAlternative: String,
        defaultAlternativeTag: String,
        stationHolidays: [StationHoliday] = []
    ) -> TimeCalculationDetails? {
        guard let stationTimeZone = TimeZone(identifier: station.timeZone),
              let selection = transportSelection(
                departure: departure,
                station: station,
                stationTimeZone: stationTimeZone,
                selectedAlternative: selectedAlternative,
                defaultAlternativeTag: defaultAlternativeTag,
                stationHolidays: stationHolidays
              ) else {
            return nil
        }
        let report = reportTime
            ?? departure.addingTimeInterval(-60 * 60)
        guard report <= departure else {
            return nil
        }

        switch selection {
        case .exact(let minutes, let label):
            let pickup = report.addingTimeInterval(
                TimeInterval(-minutes * 60)
            )
            let wakeup = pickup.addingTimeInterval(-60 * 60)
            return TimeCalculationDetails(
                departure: departure,
                report: report,
                pickup: TimeCalculationWindow(
                    earliest: pickup,
                    latest: pickup
                ),
                wakeup: TimeCalculationWindow(
                    earliest: wakeup,
                    latest: wakeup
                ),
                minimumTransportMinutes: minutes,
                maximumTransportMinutes: minutes,
                usesTransportRange: false,
                appliedRuleLabel: label
            )
        case .range(let minimum, let maximum, let label):
            let pickupFrom = report.addingTimeInterval(
                TimeInterval(-maximum * 60)
            )
            let pickupTo = report.addingTimeInterval(
                TimeInterval(-minimum * 60)
            )
            return TimeCalculationDetails(
                departure: departure,
                report: report,
                pickup: TimeCalculationWindow(
                    earliest: pickupFrom,
                    latest: pickupTo
                ),
                wakeup: TimeCalculationWindow(
                    earliest: pickupFrom.addingTimeInterval(-60 * 60),
                    latest: pickupTo.addingTimeInterval(-60 * 60)
                ),
                minimumTransportMinutes: minimum,
                maximumTransportMinutes: maximum,
                usesTransportRange: true,
                appliedRuleLabel: label
            )
        }
    }

    private enum TransportSelection {
        case exact(minutes: Int, label: String?)
        case range(minimum: Int, maximum: Int, label: String?)
    }

    private static func transportSelection(
        departure: Date,
        station: Station,
        stationTimeZone: TimeZone,
        selectedAlternative: String,
        defaultAlternativeTag: String,
        stationHolidays: [StationHoliday]
    ) -> TransportSelection? {

        let departureLocalMinutes = minutesOfDay(for: departure, in: stationTimeZone)
        let isWeekend = isWeekend(date: departure, in: stationTimeZone)
        let isPublicHoliday = isPublicHoliday(
            date: departure,
            in: stationTimeZone,
            stationHolidays: stationHolidays
        )

        if selectedAlternative != defaultAlternativeTag,
           let alternative = station.alternatives.first(where: { $0.label == selectedAlternative }) {
            return .exact(
                minutes: alternative.transportMinutes,
                label: alternative.label
            )
        }

        if let condition = matchingCondition(
            in: station.defaultRule.conditions,
            departureLocalMinutes: departureLocalMinutes,
            isWeekend: isWeekend,
            isPublicHoliday: isPublicHoliday
        ) {
            return .exact(
                minutes: condition.transportMinutes,
                label: condition.label
            )
        }

        switch station.defaultRule.type {
        case "fixed":
            guard let transport = station.defaultRule.transportMinutes else { return nil }
            return .exact(
                minutes: transport,
                label: station.defaultRule.label
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
                    return .exact(
                        minutes: rule.transportMinutes,
                        label: rule.label
                    )
                }

                let from = parse(time: fromLocal)
                let to = parse(time: toLocal)

                if isTime(departureLocalMinutes, insideFrom: from, to: to) {
                    return .exact(
                        minutes: rule.transportMinutes,
                        label: rule.label
                    )
                }
            }

            return nil

        case "range":
            guard let min = station.defaultRule.minTransportMinutes,
                  let max = station.defaultRule.maxTransportMinutes else {
                return nil
            }

            return .range(
                minimum: min,
                maximum: max,
                label: station.defaultRule.label
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

        guard let departureUTC = makeDepartureDate(
            hour: selectedHour,
            minute: selectedMinute,
            etdDate: etdDate,
            inputReference: inputReference,
            stationTimeZone: stationTimeZone
        ) else {
            return "Invalid local time"
        }

        return "\(format(departureUTC, in: stationTimeZone)) \(station.iata) / \(format(departureUTC, in: lisTimeZone)) LIS / \(format(departureUTC, in: utcTimeZone)) UTC"
    }

    private static func formattedResult(
        _ details: TimeCalculationDetails,
        station: Station,
        stationTimeZone: TimeZone
    ) -> CalculationResult {
        let pickup: String
        let wakeup: String
        let transportTime: String

        if details.usesTransportRange {
            pickup = formatRange(
                from: details.pickup.earliest,
                to: details.pickup.latest,
                station: station,
                stationTimeZone: stationTimeZone
            )
            wakeup = formatRange(
                from: details.wakeup.earliest,
                to: details.wakeup.latest,
                station: station,
                stationTimeZone: stationTimeZone
            )
            transportTime = "up to \(details.maximumTransportMinutes) min"
        } else {
            pickup = formatDualTime(
                details.pickup.earliest,
                station: station,
                stationTimeZone: stationTimeZone
            )
            wakeup = formatDualTime(
                details.wakeup.earliest,
                station: station,
                stationTimeZone: stationTimeZone
            )
            transportTime = "\(details.maximumTransportMinutes) min"
        }

        return CalculationResult(
            pickup: pickup,
            wakeup: wakeup,
            transportTime: transportTime,
            appliedRuleLabel: details.appliedRuleLabel
        )
    }

    private static func makeDepartureDate(
        hour: Int,
        minute: Int,
        etdDate: Date,
        inputReference: TimeInputReference,
        stationTimeZone: TimeZone
    ) -> Date? {
        guard (0..<24).contains(hour),
              (0..<60).contains(minute) else {
            return nil
        }
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
        displayCalendar.locale = Locale(identifier: "en_US_POSIX")
        displayCalendar.timeZone = Calendar.current.timeZone

        let dateComponents = displayCalendar.dateComponents(
            [.year, .month, .day],
            from: etdDate
        )
        guard let year = dateComponents.year,
              let month = dateComponents.month,
              let day = dateComponents.day else {
            return nil
        }

        return resolveLocalDate(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            in: inputTimeZone
        )
    }

    private static func resolveLocalDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        in timeZone: TimeZone
    ) -> Date? {
        guard let utc = TimeZone(secondsFromGMT: 0) else {
            return nil
        }
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.locale = Locale(identifier: "en_US_POSIX")
        utcCalendar.timeZone = utc
        guard let localFieldsAsUTC = utcCalendar.date(from: DateComponents(
            timeZone: utc,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: 0
        )) else {
            return nil
        }

        // A repeated wall time has two offsets; a skipped wall time has none.
        let probeOffsets = [-172_800, -86_400, 0, 86_400, 172_800]
        let possibleOffsets = Set(probeOffsets.map {
            timeZone.secondsFromGMT(
                for: localFieldsAsUTC.addingTimeInterval(TimeInterval($0))
            )
        })
        let candidates = Set(possibleOffsets.compactMap { offset -> Date? in
            let candidate = localFieldsAsUTC.addingTimeInterval(
                TimeInterval(-offset)
            )
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = Locale(identifier: "en_US_POSIX")
            calendar.timeZone = timeZone
            let actual = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: candidate
            )
            guard actual.year == year,
                  actual.month == month,
                  actual.day == day,
                  actual.hour == hour,
                  actual.minute == minute,
                  actual.second == 0 else {
                return nil
            }
            return candidate
        })
        guard candidates.count == 1 else {
            return nil
        }
        return candidates.first
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
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)

        return String(format: "%02d:%02d", hour, minute)
    }
}
