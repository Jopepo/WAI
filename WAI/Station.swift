import Foundation

struct Station: Codable, Identifiable {

    var id: String { iata }

    let iata: String
    let icao: String
    let city: String
    let country: String

    let timeZone: String
    let standardUtcOffset: String
    let summerUtcOffset: String

    let defaultRule: TransportRule
    let alternatives: [TransportAlternative]
    let holidays: [StationHoliday]?

    var isValid: Bool {
        let alternativeLabels = alternatives.map(\.label)
        let stationHolidays = holidays ?? []
        let holidayDates = stationHolidays.map(\.date)

        return OperationalDataFormat.isIdentifier(
            iata,
            length: 3,
            allowsDigits: false
        )
        && OperationalDataFormat.isIdentifier(
            icao,
            length: 4,
            allowsDigits: true
        )
        && OperationalDataFormat.isBoundedText(city, maximumBytes: 256)
        && OperationalDataFormat.isBoundedText(country, maximumBytes: 256)
        && OperationalDataFormat.isBoundedText(timeZone, maximumBytes: 128)
        && TimeZone(identifier: timeZone) != nil
        && TransportTimeFormat.isValidUTCOffset(standardUtcOffset)
        && TransportTimeFormat.isValidUTCOffset(summerUtcOffset)
        && defaultRule.isValid
        && alternatives.count <= 50
        && Set(alternativeLabels).count == alternativeLabels.count
        && alternatives.allSatisfy(\.isValid)
        && stationHolidays.count <= 3_660
        && Set(holidayDates).count == holidayDates.count
        && stationHolidays.allSatisfy(\.isValid)
    }
}

struct TransportRule: Codable {

    let type: String
    let label: String?

    let transportMinutes: Int?

    let minTransportMinutes: Int?
    let maxTransportMinutes: Int?

    let rules: [TimeRule]?
    let conditions: [TransportCondition]?

    var isValid: Bool {
        let ruleConditions = conditions ?? []
        let conditionLabels = ruleConditions.map(\.label)
        let conditionsAreValid = ruleConditions.count <= 100
            && Set(conditionLabels).count == conditionLabels.count
            && ruleConditions.allSatisfy(\.isValid)

        guard OperationalDataFormat.isOptionalBoundedText(
            label,
            maximumBytes: 256
        ) else {
            return false
        }

        switch type {
        case "fixed":
            return transportMinutes.map(
                TransportTimeFormat.isValidTransportMinutes
            ) == true && conditionsAreValid
        case "range":
            guard let minTransportMinutes,
                  let maxTransportMinutes else {
                return false
            }

            return TransportTimeFormat.isValidTransportMinutes(
                minTransportMinutes
            )
            && TransportTimeFormat.isValidTransportMinutes(
                maxTransportMinutes
            )
            && maxTransportMinutes >= minTransportMinutes
            && conditionsAreValid
        case "timeDependent":
            guard let rules,
                  !rules.isEmpty,
                  rules.count <= 100 else {
                return false
            }

            return rules.allSatisfy(\.isValid) && conditionsAreValid
        default:
            return false
        }
    }
}

struct TimeRule: Codable {

    let label: String?

    let fromLocal: String?
    let toLocal: String?

    let weekdaysOnly: Bool?
    let weekendsAndHolidaysOnly: Bool?
    let publicHolidaysOnly: Bool?

    let transportMinutes: Int

    var isValid: Bool {
        OperationalDataFormat.isOptionalBoundedText(
            label,
            maximumBytes: 256
        )
        && TransportTimeFormat.hasCompleteTimeWindow(
            fromLocal: fromLocal,
            toLocal: toLocal
        )
        && OperationalDataFormat.hasAtMostOneTrue([
            weekdaysOnly,
            weekendsAndHolidaysOnly,
            publicHolidaysOnly
        ])
        && TransportTimeFormat.isValidTransportMinutes(transportMinutes)
        && TransportTimeFormat.isValidOptionalTime(fromLocal)
        && TransportTimeFormat.isValidOptionalTime(toLocal)
    }
}

struct TransportCondition: Codable, Identifiable {

    var id: String { label }

    let label: String
    let fromLocal: String?
    let toLocal: String?
    let appliesOnWeekdays: Bool?
    let appliesOnWeekends: Bool?
    let appliesOnPublicHolidays: Bool?
    let transportMinutes: Int

    var isValid: Bool {
        OperationalDataFormat.isBoundedText(label, maximumBytes: 256)
        && TransportTimeFormat.hasCompleteTimeWindow(
            fromLocal: fromLocal,
            toLocal: toLocal
        )
        && OperationalDataFormat.hasAtMostOneTrue([
            appliesOnWeekdays,
            appliesOnWeekends,
            appliesOnPublicHolidays
        ])
        && TransportTimeFormat.isValidTransportMinutes(transportMinutes)
        && TransportTimeFormat.isValidOptionalTime(fromLocal)
        && TransportTimeFormat.isValidOptionalTime(toLocal)
    }
}

struct StationHoliday: Codable, Identifiable {

    var id: String { date }

    let date: String
    let name: String

    var isValid: Bool {
        OperationalDataFormat.isBoundedText(name, maximumBytes: 256)
        && TransportTimeFormat.isValidISODate(date)
    }
}

enum OperationalDataFormat {
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

    static func isIdentifier(
        _ value: String,
        length: Int,
        allowsDigits: Bool
    ) -> Bool {
        let bytes = value.utf8
        return bytes.count == length && bytes.allSatisfy { byte in
            (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (allowsDigits
                && (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte))
        }
    }

    static func hasAtMostOneTrue(_ values: [Bool?]) -> Bool {
        values.lazy.filter { $0 == true }.count <= 1
    }
}

enum TransportTimeFormat {
    static let maximumTransportMinutes = 24 * 60

    static func isValidTransportMinutes(_ value: Int) -> Bool {
        (0...maximumTransportMinutes).contains(value)
    }

    static func isValidOptionalTime(_ value: String?) -> Bool {
        guard let value else {
            return true
        }

        let bytes = Array(value.utf8)
        guard bytes.count == 5,
              bytes[2] == UInt8(ascii: ":"),
              bytes.enumerated().allSatisfy({ index, byte in
                  index == 2
                  || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
              }) else {
            return false
        }

        let hour = Int(bytes[0] - UInt8(ascii: "0")) * 10
            + Int(bytes[1] - UInt8(ascii: "0"))
        let minute = Int(bytes[3] - UInt8(ascii: "0")) * 10
            + Int(bytes[4] - UInt8(ascii: "0"))

        return (0...23).contains(hour) && (0...59).contains(minute)
    }

    static func hasCompleteTimeWindow(
        fromLocal: String?,
        toLocal: String?
    ) -> Bool {
        (fromLocal == nil) == (toLocal == nil)
    }

    static func isValidUTCOffset(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 6,
              bytes[0] == UInt8(ascii: "+")
                || bytes[0] == UInt8(ascii: "-"),
              bytes[3] == UInt8(ascii: ":"),
              bytes.dropFirst().enumerated().allSatisfy({ index, byte in
                  index == 2
                  || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
              }) else {
            return false
        }

        let hour = Int(bytes[1] - UInt8(ascii: "0")) * 10
            + Int(bytes[2] - UInt8(ascii: "0"))
        let minute = Int(bytes[4] - UInt8(ascii: "0")) * 10
            + Int(bytes[5] - UInt8(ascii: "0"))
        return (0...14).contains(hour)
            && (0...59).contains(minute)
            && (hour < 14 || minute == 0)
    }

    static func isValidISODate(_ value: String) -> Bool {
        guard value.utf8.count == 10 else {
            return false
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else {
            return false
        }
        return formatter.string(from: date) == value
    }
}

enum TimeInputReference: String, Codable, CaseIterable, Identifiable {

    case utc
    case stationLocal
    case lisbon

    var id: String { rawValue }

    var title: String {
        switch self {
        case .utc:
            return "UTC"
        case .stationLocal:
            return "Local"
        case .lisbon:
            return "Lisbon"
        }
    }
}

struct CalculationHistoryItem: Codable, Identifiable, Equatable {

    let id: UUID
    let createdAt: Date
    let stationIATA: String
    let stationCity: String
    let etdDate: Date
    let inputReference: TimeInputReference
    let inputTimeText: String
    let pickupTimeText: String
    let wakeupTimeText: String
    var roomNumber: String?
    let appliedRuleLabel: String?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        stationIATA: String,
        stationCity: String,
        etdDate: Date,
        inputReference: TimeInputReference,
        inputTimeText: String,
        pickupTimeText: String,
        wakeupTimeText: String,
        roomNumber: String? = nil,
        appliedRuleLabel: String?
    ) {
        self.id = id
        self.createdAt = createdAt
        self.stationIATA = stationIATA
        self.stationCity = stationCity
        self.etdDate = etdDate
        self.inputReference = inputReference
        self.inputTimeText = inputTimeText
        self.pickupTimeText = pickupTimeText
        self.wakeupTimeText = wakeupTimeText
        self.roomNumber = roomNumber
        self.appliedRuleLabel = appliedRuleLabel
    }
}

struct TransportAlternative: Codable, Identifiable {

    var id: String { label }

    let label: String
    let transportMinutes: Int

    var isValid: Bool {
        OperationalDataFormat.isBoundedText(label, maximumBytes: 256)
        && TransportTimeFormat.isValidTransportMinutes(transportMinutes)
    }
}
