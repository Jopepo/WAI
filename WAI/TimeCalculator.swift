import Foundation

struct CalculationResult {
    let pickup: String
    let wakeup: String
    let transportTime: String
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
        guard let stationTimeZone = TimeZone(identifier: station.timeZone) else {
            return nil
        }

        let departureUTC = makeUTCDate(
            hour: selectedHour,
            minute: selectedMinute,
            referenceDate: referenceDate
        )

        let departureLocalMinutes = minutesOfDay(for: departureUTC, in: stationTimeZone)
        let isWeekend = isWeekend(date: departureUTC, in: stationTimeZone)

        if selectedAlternative != defaultAlternativeTag,
           let alternative = station.alternatives.first(where: { $0.label == selectedAlternative }) {
            return exactResult(
                departureUTC: departureUTC,
                transportMinutes: alternative.transportMinutes,
                station: station,
                stationTimeZone: stationTimeZone
            )
        }

        switch station.defaultRule.type {
        case "fixed":
            guard let transport = station.defaultRule.transportMinutes else { return nil }
            return exactResult(
                departureUTC: departureUTC,
                transportMinutes: transport,
                station: station,
                stationTimeZone: stationTimeZone
            )

        case "timeDependent":
            guard let rules = station.defaultRule.rules else { return nil }

            for rule in rules {
                if rule.weekendsAndHolidaysOnly == true {
                    guard isWeekend else { continue }
                    return exactResult(
                        departureUTC: departureUTC,
                        transportMinutes: rule.transportMinutes,
                        station: station,
                        stationTimeZone: stationTimeZone
                    )
                }

                if rule.weekdaysOnly == true && isWeekend {
                    continue
                }

                guard let fromLocal = rule.fromLocal,
                      let toLocal = rule.toLocal else {
                    continue
                }

                let from = parse(time: fromLocal)
                let to = parse(time: toLocal)

                if isTime(departureLocalMinutes, insideFrom: from, to: to) {
                    return exactResult(
                        departureUTC: departureUTC,
                        transportMinutes: rule.transportMinutes,
                        station: station,
                        stationTimeZone: stationTimeZone
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
                pickup: "\(formatRange(from: pickupFromUTC, to: pickupToUTC, station: station, stationTimeZone: stationTimeZone))",
                wakeup: "\(formatRange(from: wakeupFromUTC, to: wakeupToUTC, station: station, stationTimeZone: stationTimeZone))",
                transportTime: "up to \(max) min"
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
        guard let stationTimeZone = TimeZone(identifier: station.timeZone) else {
            return String(format: "%02d:%02d UTC", selectedHour, selectedMinute)
        }

        let departureUTC = makeUTCDate(
            hour: selectedHour,
            minute: selectedMinute,
            referenceDate: referenceDate
        )

        return "\(format(departureUTC, in: stationTimeZone)) \(station.iata) / \(format(departureUTC, in: lisTimeZone)) LIS"
    }

    private static func exactResult(
        departureUTC: Date,
        transportMinutes: Int,
        station: Station,
        stationTimeZone: TimeZone
    ) -> CalculationResult {
        let pickupUTC = departureUTC.addingTimeInterval(TimeInterval(-(60 + transportMinutes) * 60))
        let wakeupUTC = pickupUTC.addingTimeInterval(-60 * 60)

        return CalculationResult(
            pickup: formatDualTime(pickupUTC, station: station, stationTimeZone: stationTimeZone),
            wakeup: formatDualTime(wakeupUTC, station: station, stationTimeZone: stationTimeZone),
            transportTime: "\(transportMinutes) min"
        )
    }

    private static func makeUTCDate(hour: Int, minute: Int, referenceDate: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utcTimeZone

        let components = calendar.dateComponents([.year, .month, .day], from: referenceDate)

        return calendar.date(from: DateComponents(
            timeZone: utcTimeZone,
            year: components.year,
            month: components.month,
            day: components.day,
            hour: hour,
            minute: minute
        )) ?? referenceDate
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
