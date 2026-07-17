import Foundation

enum RosterCompany: String, Codable, Equatable, Sendable {
    case tap
}

enum RosterDutyKind: String, Codable, Equatable, Sendable {
    case flight
    case activity
}

struct RosterCoveragePeriod: Codable, Equatable, Sendable {
    let start: Date
    let end: Date
    let timeZoneIdentifier: String

    var isValid: Bool {
        RosterValueFormat.isFinite(start)
        && RosterValueFormat.isFinite(end)
        && start < end
        && RosterValueFormat.isBoundedText(
            timeZoneIdentifier,
            maximumBytes: 128
        )
        && TimeZone(identifier: timeZoneIdentifier) != nil
    }
}

struct RosterSource: Codable, Equatable, Sendable {
    let company: RosterCompany
    let productIdentifier: String?
    let calendarName: String?
    let crewIdentifier: String?
    let sourceName: String?
    let sha256: String
    let importedAt: Date

    var isValid: Bool {
        RosterValueFormat.isOptionalBoundedText(
            productIdentifier,
            maximumBytes: 256
        )
        && RosterValueFormat.isOptionalBoundedText(
            calendarName,
            maximumBytes: 512
        )
        && RosterValueFormat.isOptionalBoundedText(
            crewIdentifier,
            maximumBytes: 128
        )
        && RosterValueFormat.isOptionalBoundedText(
            sourceName,
            maximumBytes: 512
        )
        && RosterValueFormat.isFinite(importedAt)
        && sha256.utf8.count == 64
        && sha256.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }
}

struct RosterLocalDateTime: Codable, Equatable, Sendable {
    let year: Int
    let month: Int
    let day: Int
    let hour: Int
    let minute: Int
    let timeZoneIdentifier: String?
    let instant: Date?

    var isValid: Bool {
        guard let utc = TimeZone(secondsFromGMT: 0),
              (1...9_999).contains(year),
              (1...12).contains(month),
              (1...31).contains(day),
              (0...23).contains(hour),
              (0...59).contains(minute),
              RosterValueFormat.resolvesExactly(
                  year: year,
                  month: month,
                  day: day,
                  hour: hour,
                  minute: minute,
                  timeZone: utc
              ) != nil else {
            return false
        }

        if let timeZoneIdentifier {
            guard RosterValueFormat.isBoundedText(
                      timeZoneIdentifier,
                      maximumBytes: 128
                  ),
                  let timeZone = TimeZone(identifier: timeZoneIdentifier),
                  let instant,
                  RosterValueFormat.isFinite(instant),
                  RosterValueFormat.matches(
                      instant,
                      year: year,
                      month: month,
                      day: day,
                      hour: hour,
                      minute: minute,
                      timeZone: timeZone
                  ) else {
                return false
            }
        } else if instant != nil {
            return false
        }

        return true
    }
}

struct RosterCrewMember: Codable, Equatable, Sendable, Identifiable {
    let employeeIdentifier: String
    let roleCode: String
    let name: String
    let isDeadhead: Bool

    var id: String {
        "\(employeeIdentifier)-\(roleCode)-\(isDeadhead)"
    }

    var isValid: Bool {
        RosterValueFormat.isBoundedText(
            employeeIdentifier,
            maximumBytes: 128
        )
        && RosterValueFormat.isBoundedText(roleCode, maximumBytes: 32)
        && RosterValueFormat.isBoundedText(name, maximumBytes: 512)
    }
}

struct RosterLeg: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let flightNumber: String
    let departure: RosterLocalDateTime
    let arrival: RosterLocalDateTime
    let originIATA: String
    let originName: String?
    let destinationIATA: String
    let destinationName: String?
    let aircraftRegistration: String?
    let aircraftName: String?
    let passengerLoad: String?
    let cosmicRadiation: Double?
    let crew: [RosterCrewMember]

    var blockMinutes: Int? {
        guard let departure = departure.instant,
              let arrival = arrival.instant,
              arrival > departure else {
            return nil
        }
        return Int(arrival.timeIntervalSince(departure) / 60)
    }

    var isValid: Bool {
        guard RosterValueFormat.isBoundedText(id, maximumBytes: 256),
              RosterValueFormat.isBoundedText(
                  flightNumber,
                  maximumBytes: 64
              ),
              Self.isIATA(originIATA),
              Self.isIATA(destinationIATA),
              RosterValueFormat.isOptionalBoundedText(
                  originName,
                  maximumBytes: 512
              ),
              RosterValueFormat.isOptionalBoundedText(
                  destinationName,
                  maximumBytes: 512
              ),
              RosterValueFormat.isOptionalBoundedText(
                  aircraftRegistration,
                  maximumBytes: 128
              ),
              RosterValueFormat.isOptionalBoundedText(
                  aircraftName,
                  maximumBytes: 512
              ),
              RosterValueFormat.isOptionalBoundedText(
                  passengerLoad,
                  maximumBytes: 128
              ),
              cosmicRadiation.map({ $0.isFinite && $0 >= 0 }) != false,
              departure.isValid,
              arrival.isValid,
              crew.count <= 100,
              crew.allSatisfy(\.isValid) else {
            return false
        }

        if let departureInstant = departure.instant,
           let arrivalInstant = arrival.instant,
           arrivalInstant <= departureInstant {
            return false
        }

        return true
    }

    private static func isIATA(_ value: String) -> Bool {
        value.utf8.count == 3 && value.utf8.allSatisfy { byte in
            (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
        }
    }
}

struct RosterDuty: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let activityCode: String
    let start: Date
    let end: Date
    let timeZoneIdentifier: String
    let kind: RosterDutyKind
    let hotelCode: String?
    let legs: [RosterLeg]

    var startTimeZoneIdentifier: String {
        legs.first?.departure.timeZoneIdentifier ?? timeZoneIdentifier
    }

    var endTimeZoneIdentifier: String {
        legs.last?.arrival.timeZoneIdentifier ?? timeZoneIdentifier
    }

    var isValid: Bool {
        guard RosterValueFormat.isBoundedText(id, maximumBytes: 256),
              RosterValueFormat.isBoundedText(
                  activityCode,
                  maximumBytes: 128
              ),
              RosterValueFormat.isFinite(start),
              RosterValueFormat.isFinite(end),
              start < end,
              RosterValueFormat.isBoundedText(
                  timeZoneIdentifier,
                  maximumBytes: 128
              ),
              TimeZone(identifier: timeZoneIdentifier) != nil,
              RosterValueFormat.isOptionalIdentifier(
                  hotelCode,
                  maximumBytes: 32
              ),
              legs.count <= 20,
              legs.allSatisfy(\.isValid),
              legs.allSatisfy({ leg in
                  let departureIsInsideDuty = leg.departure.instant.map {
                      start <= $0 && $0 <= end
                  } ?? true
                  let arrivalIsInsideDuty = leg.arrival.instant.map {
                      start <= $0 && $0 <= end
                  } ?? true
                  return departureIsInsideDuty && arrivalIsInsideDuty
              }),
              Set(legs.map(\.id)).count == legs.count else {
            return false
        }

        return kind == (legs.isEmpty ? .activity : .flight)
    }
}

struct RosterDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let source: RosterSource
    let coverage: RosterCoveragePeriod
    let duties: [RosterDuty]

    init(
        schemaVersion: Int = currentSchemaVersion,
        source: RosterSource,
        coverage: RosterCoveragePeriod,
        duties: [RosterDuty]
    ) {
        self.schemaVersion = schemaVersion
        self.source = source
        self.coverage = coverage
        self.duties = duties
    }

    var isValid: Bool {
        schemaVersion == Self.currentSchemaVersion
        && source.isValid
        && coverage.isValid
        && !duties.isEmpty
        && duties.count <= 5_000
        && duties.allSatisfy(\.isValid)
        && Set(duties.map(\.id)).count == duties.count
        && duties.allSatisfy {
            $0.end > coverage.start && $0.start < coverage.end
        }
    }
}

enum RosterImportIssueCode: String, Codable, Equatable, Hashable, Sendable {
    case unresolvedStationTimeZone
}

struct RosterImportIssue: Codable, Equatable, Hashable, Sendable, Identifiable {
    let code: RosterImportIssueCode
    let dutyID: String
    let flightNumber: String
    let stationIATA: String

    var id: String {
        "\(code.rawValue)-\(dutyID)-\(flightNumber)-\(stationIATA)"
    }

    var isValid: Bool {
        RosterValueFormat.isBoundedText(dutyID, maximumBytes: 256)
        && RosterValueFormat.isBoundedText(
            flightNumber,
            maximumBytes: 64
        )
        && stationIATA.utf8.count == 3
        && stationIATA.utf8.allSatisfy { byte in
            (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
        }
    }
}

struct RosterImportResult: Equatable, Sendable {
    let document: RosterDocument
    let issues: [RosterImportIssue]
}

private enum RosterValueFormat {
    static func isBoundedText(_ value: String, maximumBytes: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && value.utf8.count <= maximumBytes
    }

    static func isOptionalBoundedText(
        _ value: String?,
        maximumBytes: Int
    ) -> Bool {
        value.map { isBoundedText($0, maximumBytes: maximumBytes) } ?? true
    }

    static func isOptionalIdentifier(
        _ value: String?,
        maximumBytes: Int
    ) -> Bool {
        guard let value else {
            return true
        }
        return (1...maximumBytes).contains(value.utf8.count)
        && value.utf8.allSatisfy { byte in
            (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
        }
    }

    static func isFinite(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite
    }

    static func resolvesExactly(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        timeZone: TimeZone
    ) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        let requested = DateComponents(
            timeZone: timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: 0
        )
        guard let date = calendar.date(from: requested),
              matches(
                  date,
                  year: year,
                  month: month,
                  day: day,
                  hour: hour,
                  minute: minute,
                  timeZone: timeZone
              ) else {
            return nil
        }
        return date
    }

    static func matches(
        _ date: Date,
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        timeZone: TimeZone
    ) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        let actual = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: date
        )
        return actual.year == year
        && actual.month == month
        && actual.day == day
        && actual.hour == hour
        && actual.minute == minute
    }
}
