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
}

struct TimeRule: Codable {

    let label: String?

    let fromLocal: String?
    let toLocal: String?

    let weekdaysOnly: Bool?
    let weekendsAndHolidaysOnly: Bool?
    let publicHolidaysOnly: Bool?

    let transportMinutes: Int
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
}

struct StationHoliday: Codable, Identifiable {

    var id: String { date }

    let date: String
    let name: String
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
    let roomNumber: String?
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
