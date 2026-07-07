import Foundation

struct HotelStay: Codable, Identifiable {
    let id: UUID
    var sourceCalculationID: UUID?
    let stationIATA: String
    let hotelName: String
    let city: String
    let country: String
    var roomNumber: String
    let etdDate: Date
    var etdTimeText: String?
    var registeredAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        sourceCalculationID: UUID?,
        stationIATA: String,
        hotelName: String,
        city: String,
        country: String,
        roomNumber: String,
        etdDate: Date,
        etdTimeText: String? = nil,
        registeredAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.sourceCalculationID = sourceCalculationID
        self.stationIATA = stationIATA
        self.hotelName = hotelName
        self.city = city
        self.country = country
        self.roomNumber = roomNumber
        self.etdDate = etdDate
        self.etdTimeText = etdTimeText
        self.registeredAt = registeredAt
        self.updatedAt = updatedAt
    }
}

@MainActor
final class HotelStayStore: ObservableObject {
    static let shared = HotelStayStore()

    @Published private(set) var stays: [HotelStay] = []

    private let staysKey = "wai.hotelStays"

    private init() {
        load()
    }

    func stays(for hotel: Hotel) -> [HotelStay] {
        stays
            .filter { $0.stationIATA == hotel.iata && $0.hotelName == hotel.name }
            .sorted { $0.registeredAt > $1.registeredAt }
    }

    func upsertStay(
        for item: CalculationHistoryItem,
        hotel: Hotel,
        roomNumber: String
    ) {
        let trimmedRoomNumber = roomNumber.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedRoomNumber.isEmpty else {
            return
        }

        if let index = stays.firstIndex(where: { $0.sourceCalculationID == item.id }) {
            stays[index].roomNumber = trimmedRoomNumber
            stays[index].etdTimeText = item.inputTimeText
            stays[index].updatedAt = Date()
        } else {
            stays.insert(
                HotelStay(
                    sourceCalculationID: item.id,
                    stationIATA: hotel.iata,
                    hotelName: hotel.name,
                    city: hotel.city,
                    country: hotel.country,
                    roomNumber: trimmedRoomNumber,
                    etdDate: item.etdDate,
                    etdTimeText: item.inputTimeText
                ),
                at: 0
            )
        }

        persist()
    }

    func removeStay(for item: CalculationHistoryItem) {
        stays.removeAll { $0.sourceCalculationID == item.id }
        persist()
    }

    func delete(_ stay: HotelStay) {
        stays.removeAll { $0.id == stay.id }
        persist()
    }

    func detachCalculation(_ item: CalculationHistoryItem) {
        guard let index = stays.firstIndex(where: { $0.sourceCalculationID == item.id }) else {
            return
        }

        stays[index].sourceCalculationID = nil
        stays[index].updatedAt = Date()
        persist()
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let data = UserDefaults.standard.data(forKey: staysKey),
              let decodedStays = try? decoder.decode([HotelStay].self, from: data) else {
            return
        }

        stays = decodedStays
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(stays) else {
            return
        }

        UserDefaults.standard.set(data, forKey: staysKey)
    }
}
