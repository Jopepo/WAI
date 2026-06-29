import Foundation

final class HotelDataService {
    static let shared = HotelDataService()

    private(set) var hotels: [Hotel] = []
    private(set) var document: HotelDocument?

    private init() {
        loadHotels()
    }

    func hotel(for stationIATA: String) -> Hotel? {
        hotels.first { $0.iata == stationIATA }
    }

    private func loadHotels() {
        guard let url = Bundle.main.url(forResource: "wai_hotel_map_rev51", withExtension: "json") else {
            print("Hotel JSON file not found")
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(HotelDocument.self, from: data)
            document = decoded
            hotels = decoded.hotels
            print("Loaded \(decoded.hotels.count) hotels")
        } catch {
            print("Failed to load hotel data: \(error)")
        }
    }
}
