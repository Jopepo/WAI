import Foundation

struct HotelDocument: Codable {
    let document: String
    let revision: String
    let date: String
    let hotels: [Hotel]
}

struct Hotel: Codable, Identifiable {
    var id: String { iata }

    let iata: String
    let icao: String
    let city: String
    let country: String
    let name: String
    let phone: String?
    let email: String?
    let fax: String?

    var mapsQuery: String {
        "\(name) \(city)"
    }
}
