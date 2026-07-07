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
        let conditionsAreValid = (conditions ?? []).allSatisfy(\.isValid)

        switch type {
        case "fixed":
            return transportMinutes.map { $0 >= 0 } == true && conditionsAreValid
        case "range":
            guard let minTransportMinutes,
                  let maxTransportMinutes else {
                return false
            }

            return minTransportMinutes >= 0
            && maxTransportMinutes >= minTransportMinutes
            && conditionsAreValid
        case "timeDependent":
            guard let rules,
                  !rules.isEmpty else {
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
        transportMinutes >= 0
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
        !label.isEmpty
        && transportMinutes >= 0
        && TransportTimeFormat.isValidOptionalTime(fromLocal)
        && TransportTimeFormat.isValidOptionalTime(toLocal)
    }
}

struct StationHoliday: Codable, Identifiable {

    var id: String { date }

    let date: String
    let name: String

    var isValid: Bool {
        !name.isEmpty && TransportTimeFormat.isValidISODate(date)
    }
}

enum TransportTimeFormat {
    static func isValidOptionalTime(_ value: String?) -> Bool {
        guard let value else {
            return true
        }

        let components = value.split(separator: ":")
        guard components.count == 2,
              let hour = Int(components[0]),
              let minute = Int(components[1]) else {
            return false
        }

        return (0...23).contains(hour) && (0...59).contains(minute)
    }

    static func isValidISODate(_ value: String) -> Bool {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: value) != nil
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

struct CalculationHistoryItem: Codable, Identifiable {

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
}
