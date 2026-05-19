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
}

struct TransportRule: Codable {

    let type: String
    let label: String?

    let transportMinutes: Int?

    let minTransportMinutes: Int?
    let maxTransportMinutes: Int?

    let rules: [TimeRule]?
}

struct TimeRule: Codable {

    let label: String?

    let fromLocal: String?
    let toLocal: String?

    let weekdaysOnly: Bool?
    let weekendsAndHolidaysOnly: Bool?

    let transportMinutes: Int
}

struct TransportAlternative: Codable, Identifiable {

    var id: String { label }

    let label: String
    let transportMinutes: Int
}
