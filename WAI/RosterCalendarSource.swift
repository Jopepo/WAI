import CryptoKit
import EventKit
import Foundation

enum WAIRosterCalendarAuthorization: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

enum WAIBriefingCalendarSyncResult: Equatable, Sendable {
    case synced(calendarTitle: String)
    case removed(calendarTitle: String)
    case notAuthorized
    case sourceEventNotFound
    case readOnly
}

struct WAIRosterCalendarPayload: Equatable, Sendable {
    let data: Data
    let sourceName: String
}

struct WAIRosterCalendarOption: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let eventCount: Int
    let start: Date
    let end: Date
}

struct WAIRosterCalendarCandidate: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let eventCount: Int
    let start: Date
    let end: Date
    let payloads: [WAIRosterCalendarPayload]

    var option: WAIRosterCalendarOption {
        WAIRosterCalendarOption(
            id: id,
            title: title,
            eventCount: eventCount,
            start: start,
            end: end
        )
    }

    var sourceName: String {
        payloads.first?.sourceName ?? "Calendar - \(title)"
    }
}

@MainActor
protocol WAIRosterCalendarSourcing: AnyObject {
    var authorization: WAIRosterCalendarAuthorization { get }

    func requestFullAccess() async throws -> WAIRosterCalendarAuthorization
    func candidates(referenceDate: Date) throws -> [WAIRosterCalendarCandidate]
    func syncBriefingEvent(
        duty: RosterDuty,
        leg: RosterLeg,
        plannedFlightMinutes: Int?
    ) throws -> WAIBriefingCalendarSyncResult
}

extension WAIRosterCalendarSourcing {
    func syncBriefingEvent(
        duty: RosterDuty,
        leg: RosterLeg,
        plannedFlightMinutes: Int?
    ) throws -> WAIBriefingCalendarSyncResult {
        .sourceEventNotFound
    }
}

struct WAIRosterCalendarEventSnapshot: Equatable, Sendable {
    let id: String
    let calendarID: String
    let calendarTitle: String
    let title: String
    let notes: String
    let start: Date
    let end: Date
    let timeZoneIdentifier: String?
}

enum TAPRosterCalendarBuilderError: Error, Equatable {
    case invalidDateRange
    case invalidTimeZone
    case invalidEncoding
    case tooManyEvents
    case payloadTooLarge
}

struct TAPRosterCalendarBuilder {
    static let baseTimeZoneIdentifier = "Europe/Lisbon"
    static let maximumRosterEvents = 1_000
    static let maximumPayloadBytes = 5 * 1_024 * 1_024
    static let maximumEventNotesBytes = 16 * 1_024

    static func candidates(
        from snapshots: [WAIRosterCalendarEventSnapshot]
    ) throws -> [WAIRosterCalendarCandidate] {
        guard snapshots.count <= maximumRosterEvents else {
            throw TAPRosterCalendarBuilderError.tooManyEvents
        }
        guard let baseTimeZone = TimeZone(
            identifier: baseTimeZoneIdentifier
        ) else {
            throw TAPRosterCalendarBuilderError.invalidTimeZone
        }

        let eligible = snapshots.filter {
            !$0.id.isEmpty
            && $0.id.utf8.count <= 256
            && !$0.calendarID.isEmpty
            && $0.calendarID.utf8.count <= 1_024
            && !$0.calendarTitle.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
            && $0.calendarTitle.utf8.count <= 1_024
            && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && $0.title.utf8.count <= 1_024
            && isRosterEventNotes($0.notes)
            && $0.start < $0.end
        }
        let calendarGroups = Dictionary(grouping: eligible, by: \.calendarID)

        return try calendarGroups.compactMap { calendarID, events in
            guard let first = events.first else {
                return nil
            }
            let titleIdentifiesTAP = identifiesTAPCalendar(first.calendarTitle)
            let hasFlightFingerprint = events.contains {
                eventKind(for: $0.notes) == .flight
            }
            guard titleIdentifiesTAP || hasFlightFingerprint else {
                return nil
            }

            let rosterEvents = events.filter {
                eventKind(for: $0.notes) != nil
            }
            guard !rosterEvents.isEmpty,
                  let start = rosterEvents.map(\.start).min(),
                  let end = rosterEvents.map(\.end).max() else {
                return nil
            }

            let payloads = try makePayloads(
                events: rosterEvents,
                calendarTitle: first.calendarTitle,
                baseTimeZone: baseTimeZone
            )
            guard !payloads.isEmpty else {
                return nil
            }

            return WAIRosterCalendarCandidate(
                id: calendarID,
                title: normalizedTitle(first.calendarTitle),
                eventCount: rosterEvents.count,
                start: start,
                end: end,
                payloads: payloads
            )
        }
        .sorted {
            if $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedSame {
                return $0.id < $1.id
            }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private enum EventKind {
        case flight
        case activity
    }

    private struct MonthKey: Hashable, Comparable {
        let year: Int
        let month: Int

        static func < (lhs: MonthKey, rhs: MonthKey) -> Bool {
            lhs.year == rhs.year
                ? lhs.month < rhs.month
                : lhs.year < rhs.year
        }
    }

    private static func makePayloads(
        events: [WAIRosterCalendarEventSnapshot],
        calendarTitle: String,
        baseTimeZone: TimeZone
    ) throws -> [WAIRosterCalendarPayload] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = baseTimeZone

        let grouped = try Dictionary(grouping: events) { event in
            let components = calendar.dateComponents(
                [.year, .month],
                from: event.start
            )
            guard let year = components.year,
                  let month = components.month else {
                throw TAPRosterCalendarBuilderError.invalidDateRange
            }
            return MonthKey(year: year, month: month)
        }
        guard grouped.count <= 24 else {
            throw TAPRosterCalendarBuilderError.invalidDateRange
        }

        return try grouped.keys.sorted().map { month in
            guard let monthStart = calendar.date(from: DateComponents(
                timeZone: baseTimeZone,
                year: month.year,
                month: month.month,
                day: 1
            )),
            let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart),
            let monthEnd = calendar.date(byAdding: .day, value: -1, to: nextMonth) else {
                throw TAPRosterCalendarBuilderError.invalidDateRange
            }

            let coverage = "\(dayFormatter.string(from: monthStart)) a \(dayFormatter.string(from: monthEnd))"
            let usesPortalWallTimes = identifiesTAPCalendar(calendarTitle)
            var lines: [String] = []
            var payloadByteCount = 0
            try appendLines([
                "BEGIN:VCALENDAR",
                "VERSION:2.0",
                "PRODID:-//TAP Portal DOV Calendar Bridge//EN",
                "X-WR-CALNAME:\(escapeText("Escala TAP \(coverage)"))",
                "X-WR-TIMEZONE:\(baseTimeZoneIdentifier)"
            ], to: &lines, payloadByteCount: &payloadByteCount)

            for event in grouped[month, default: []].sorted(by: eventOrdering) {
                let timeZone = event.timeZoneIdentifier
                    .flatMap(TimeZone.init(identifier:))
                    ?? baseTimeZone
                let boundaryLines: [String]
                if usesPortalWallTimes {
                    boundaryLines = [
                        "TZID:\(timeZone.identifier)",
                        "DTSTART:\(dateTime(event.start, in: timeZone))",
                        "DTEND:\(dateTime(event.end, in: timeZone))"
                    ]
                } else {
                    boundaryLines = [
                        "DTSTART;TZID=\(timeZone.identifier):\(dateTime(event.start, in: timeZone))",
                        "DTEND;TZID=\(timeZone.identifier):\(dateTime(event.end, in: timeZone))"
                    ]
                }
                try appendLines(
                    ["BEGIN:VEVENT"]
                        + boundaryLines
                        + [
                            "SUMMARY:\(escapeText(event.title))",
                            "DESCRIPTION:\(escapeText(event.notes))",
                            "UID:\(escapeText(event.id))",
                            "END:VEVENT"
                        ],
                    to: &lines,
                    payloadByteCount: &payloadByteCount
                )
            }
            try appendLines(
                ["END:VCALENDAR"],
                to: &lines,
                payloadByteCount: &payloadByteCount
            )

            guard let data = lines.joined(separator: "\r\n").data(using: .utf8) else {
                throw TAPRosterCalendarBuilderError.invalidEncoding
            }
            guard data.count <= maximumPayloadBytes else {
                throw TAPRosterCalendarBuilderError.payloadTooLarge
            }
            return WAIRosterCalendarPayload(
                data: data,
                sourceName: "Calendar - \(normalizedTitle(calendarTitle))"
            )
        }
    }

    private static func eventOrdering(
        _ lhs: WAIRosterCalendarEventSnapshot,
        _ rhs: WAIRosterCalendarEventSnapshot
    ) -> Bool {
        lhs.start == rhs.start ? lhs.id < rhs.id : lhs.start < rhs.start
    }

    private static func eventKind(for notes: String) -> EventKind? {
        let value = folded(notes)
        let flightLabels = [
            "VOO ", "SAIDA:", "CHEGADA:", "ORIGEM:", "DESTINO:"
        ]
        if flightLabels.allSatisfy(value.contains) {
            return .flight
        }
        if value.contains("ACTIVIDADE:") {
            return .activity
        }
        return nil
    }

    static func isRosterEventNotes(_ notes: String) -> Bool {
        !notes.isEmpty
        && notes.utf8.count <= maximumEventNotesBytes
        && eventKind(for: notes) != nil
    }

    private static func appendLines(
        _ newLines: [String],
        to lines: inout [String],
        payloadByteCount: inout Int
    ) throws {
        for line in newLines {
            let lineBytes = line.utf8.count + 2
            guard lineBytes <= maximumPayloadBytes - payloadByteCount else {
                throw TAPRosterCalendarBuilderError.payloadTooLarge
            }
            lines.append(line)
            payloadByteCount += lineBytes
        }
    }

    private static func identifiesTAPCalendar(_ title: String) -> Bool {
        let value = folded(title)
        return value.contains("ESCALA TAP")
            || value.contains("PORTAL DOV")
            || value == "TAP"
            || value.hasPrefix("TAP ")
    }

    private static func normalizedTitle(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Roster" : trimmed
    }

    private static func folded(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .uppercased()
    }

    private static func escapeText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
    }

    private static func dateTime(_ date: Date, in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: baseTimeZoneIdentifier)
        formatter.dateFormat = "dd-MM-yyyy"
        return formatter
    }()
}

@MainActor
final class EventKitRosterCalendarSource: WAIRosterCalendarSourcing {
    private let eventStore: EKEventStore

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }

    var authorization: WAIRosterCalendarAuthorization {
        Self.authorizationStatus(
            from: EKEventStore.authorizationStatus(for: .event)
        )
    }

    func requestFullAccess() async throws -> WAIRosterCalendarAuthorization {
        _ = try await eventStore.requestFullAccessToEvents()
        return authorization
    }

    func candidates(referenceDate: Date) throws -> [WAIRosterCalendarCandidate] {
        guard authorization == .authorized else {
            return []
        }
        guard let window = Self.searchWindow(referenceDate: referenceDate) else {
            throw TAPRosterCalendarBuilderError.invalidDateRange
        }

        let calendars = eventStore.calendars(for: .event)
        let predicate = eventStore.predicateForEvents(
            withStart: window.start,
            end: window.end,
            calendars: calendars
        )
        let events = eventStore.events(matching: predicate)
        guard events.count <= 50_000 else {
            throw TAPRosterCalendarBuilderError.tooManyEvents
        }

        var snapshots: [WAIRosterCalendarEventSnapshot] = []
        snapshots.reserveCapacity(
            min(events.count, TAPRosterCalendarBuilder.maximumRosterEvents)
        )
        for event in events {
            guard let snapshot = snapshot(for: event) else {
                continue
            }
            guard snapshots.count
                    < TAPRosterCalendarBuilder.maximumRosterEvents else {
                throw TAPRosterCalendarBuilderError.tooManyEvents
            }
            snapshots.append(snapshot)
        }
        return try TAPRosterCalendarBuilder.candidates(from: snapshots)
    }

    func syncBriefingEvent(
        duty: RosterDuty,
        leg: RosterLeg,
        plannedFlightMinutes: Int?
    ) throws -> WAIBriefingCalendarSyncResult {
        guard authorization == .authorized else {
            return .notAuthorized
        }
        guard let sourceEvent = sourceEvent(for: duty),
              let calendar = sourceEvent.calendar else {
            return .sourceEventNotFound
        }
        guard calendar.allowsContentModifications else {
            return .readOnly
        }
        guard let departure = leg.departure.instant,
              let markerURL = Self.briefingEventURL(for: leg.id) else {
            return .sourceEventNotFound
        }

        let existing = briefingEvent(
            markerURL: markerURL,
            departure: departure,
            calendar: calendar
        )
        guard let plannedFlightMinutes else {
            if let existing {
                try eventStore.remove(existing, span: .thisEvent, commit: true)
            }
            return .removed(calendarTitle: calendar.title)
        }
        guard (1...1_440).contains(plannedFlightMinutes) else {
            return .sourceEventNotFound
        }

        let event = existing ?? EKEvent(eventStore: eventStore)
        event.calendar = calendar
        event.title = "WAI · \(leg.flightNumber) · \(leg.originIATA)-\(leg.destinationIATA)"
        event.startDate = departure
        event.endDate = departure.addingTimeInterval(
            Double(plannedFlightMinutes * 60)
        )
        event.timeZone = leg.departure.timeZoneIdentifier
            .flatMap(TimeZone.init(identifier:))
        event.notes = "Flight time saved from the WAI briefing."
        event.url = markerURL
        try eventStore.save(event, span: .thisEvent, commit: true)
        return .synced(calendarTitle: calendar.title)
    }

    static func briefingEventURL(for legID: String) -> URL? {
        guard !legID.isEmpty else {
            return nil
        }
        let digest = SHA256.hash(data: Data(legID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return URL(string: "wai://briefing/\(digest)")
    }

    private func sourceEvent(for duty: RosterDuty) -> EKEvent? {
        let predicate = eventStore.predicateForEvents(
            withStart: duty.start.addingTimeInterval(-60),
            end: duty.end.addingTimeInterval(60),
            calendars: eventStore.calendars(for: .event)
        )
        return eventStore.events(matching: predicate).first { event in
            guard let calendar = event.calendar,
                  let title = event.title,
                  let start = event.startDate,
                  let end = event.endDate else {
                return false
            }
            return Self.stableEventID(
                calendarID: calendar.calendarIdentifier,
                externalIdentifier: event.calendarItemExternalIdentifier,
                eventIdentifier: event.eventIdentifier,
                title: title,
                start: start,
                end: end
            ) == duty.id
        }
    }

    private func briefingEvent(
        markerURL: URL,
        departure: Date,
        calendar: EKCalendar
    ) -> EKEvent? {
        let predicate = eventStore.predicateForEvents(
            withStart: departure.addingTimeInterval(-86_400),
            end: departure.addingTimeInterval(172_800),
            calendars: [calendar]
        )
        return eventStore.events(matching: predicate).first {
            $0.url == markerURL
        }
    }

    private func snapshot(for event: EKEvent) -> WAIRosterCalendarEventSnapshot? {
        guard let calendar = event.calendar,
              let title = event.title,
              let notes = event.notes,
              let start = event.startDate,
              let end = event.endDate,
              TAPRosterCalendarBuilder.isRosterEventNotes(notes),
              !title.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty,
              title.utf8.count <= 1_024,
              calendar.title.utf8.count <= 1_024 else {
            return nil
        }

        return WAIRosterCalendarEventSnapshot(
            id: Self.stableEventID(
                calendarID: calendar.calendarIdentifier,
                externalIdentifier: event.calendarItemExternalIdentifier,
                eventIdentifier: event.eventIdentifier,
                title: title,
                start: start,
                end: end
            ),
            calendarID: calendar.calendarIdentifier,
            calendarTitle: calendar.title,
            title: title,
            notes: notes,
            start: start,
            end: end,
            timeZoneIdentifier: event.timeZone?.identifier
        )
    }

    static func stableEventID(
        calendarID: String,
        externalIdentifier: String?,
        eventIdentifier: String?,
        title: String,
        start: Date,
        end: Date
    ) -> String {
        let itemIdentifier = normalizedIdentifier(externalIdentifier)
            ?? normalizedIdentifier(eventIdentifier)
            ?? [
                title,
                String(start.timeIntervalSince1970),
                String(end.timeIntervalSince1970)
            ].joined(separator: "|")
        let identity = "\(calendarID)|\(itemIdentifier)"
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "calendar-\(digest)"
    }

    private static func normalizedIdentifier(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func authorizationStatus(
        from status: EKAuthorizationStatus
    ) -> WAIRosterCalendarAuthorization {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .denied, .writeOnly:
            return .denied
        case .restricted:
            return .restricted
        case .fullAccess:
            return .authorized
        default:
            return .denied
        }
    }

    private static func searchWindow(
        referenceDate: Date
    ) -> (start: Date, end: Date)? {
        guard let timeZone = TimeZone(identifier: TAPRosterCalendarBuilder.baseTimeZoneIdentifier) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month], from: referenceDate)
        guard let currentMonth = calendar.date(from: DateComponents(
            timeZone: timeZone,
            year: components.year,
            month: components.month,
            day: 1
        )),
        let start = calendar.date(byAdding: .month, value: -2, to: currentMonth),
        let end = calendar.date(byAdding: .month, value: 7, to: currentMonth) else {
            return nil
        }
        return (start, end)
    }
}
