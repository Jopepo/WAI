import Foundation

enum WAI3RoutineTimeResolver {
    static func timeBefore(
        _ clockTime: Date,
        anchor: Date,
        timeZoneIdentifier: String
    ) -> Date? {
        let timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let clock = calendar.dateComponents([.hour, .minute], from: clockTime)
        let anchorDay = calendar.startOfDay(for: anchor)

        for dayOffset in [0, -1] {
            guard let day = calendar.date(
                byAdding: .day,
                value: dayOffset,
                to: anchorDay
            ),
            let candidate = calendar.date(
                bySettingHour: clock.hour ?? 0,
                minute: clock.minute ?? 0,
                second: 0,
                of: day
            ) else {
                continue
            }
            if candidate < anchor {
                return candidate
            }
        }
        return nil
    }

    static func resolvedPair(
        wakeupClock: Date,
        pickupClock: Date,
        report: Date,
        timeZoneIdentifier: String
    ) -> (wakeup: Date, pickup: Date)? {
        guard let pickup = timeBefore(
            pickupClock,
            anchor: report,
            timeZoneIdentifier: timeZoneIdentifier
        ),
        let wakeup = timeBefore(
            wakeupClock,
            anchor: pickup.addingTimeInterval(60),
            timeZoneIdentifier: timeZoneIdentifier
        ),
        wakeup <= pickup else {
            return nil
        }
        return (wakeup, pickup)
    }
}

struct RosterStayRoutine: Equatable, Sendable {
    let wakeup: Date
    let pickup: Date
    let report: Date
    let usesOverride: Bool
}

enum RosterStayRoutineBuilder {
    static func routine(
        for stay: RosterStay,
        override: RosterStayRoutineOverrideRecord?
    ) -> RosterStayRoutine? {
        guard case .calculated(let details) = stay.timingStatus else {
            return nil
        }
        guard let override,
              override.stayID == stay.id,
              override.isValid else {
            return RosterStayRoutine(
                wakeup: details.wakeup.earliest,
                pickup: details.pickup.earliest,
                report: details.report,
                usesOverride: false
            )
        }
        return RosterStayRoutine(
            wakeup: details.report.addingTimeInterval(
                -Double(override.wakeupLeadMinutes * 60)
            ),
            pickup: details.report.addingTimeInterval(
                -Double(override.pickupLeadMinutes * 60)
            ),
            report: details.report,
            usesOverride: true
        )
    }
}
