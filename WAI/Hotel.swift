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

    var displayName: String {
        name
            .lowercased()
            .split(separator: " ")
            .map { word in
                let smallWords: Set<String> = ["by", "da", "de", "do", "dos", "das", "la", "le", "du", "of", "the", "and"]
                let rawWord = String(word)

                if smallWords.contains(rawWord) {
                    return rawWord
                }

                return rawWord.prefix(1).uppercased() + rawWord.dropFirst()
            }
            .joined(separator: " ")
    }

    var mapsQuery: String {
        "\(displayName) \(city)"
    }
}
