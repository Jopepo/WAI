import Foundation

extension HotelDocument: OperationalDataDocument {
    var sourceInfo: OperationalDataDocumentSource? {
        OperationalDataDocumentSource(
            document: document,
            revision: revision,
            date: date
        )
    }

    var isValid: Bool {
        guard !document.isEmpty,
              !revision.isEmpty,
              TransportTimeFormat.isValidISODate(date),
              !hotels.isEmpty else {
            return false
        }

        let iataCodes = hotels.map(\.iata)
        guard Set(iataCodes).count == iataCodes.count else {
            return false
        }

        return hotels.allSatisfy { hotel in
            hotel.iata.count == 3
            && hotel.icao.count == 4
            && !hotel.city.isEmpty
            && !hotel.country.isEmpty
            && !hotel.name.isEmpty
        }
    }
}

@MainActor
final class HotelDataService: ObservableObject {
    static let shared = HotelDataService()

    @Published private(set) var hotels: [Hotel] = []
    @Published private(set) var document: HotelDocument?
    @Published private(set) var sourceInfo = OperationalDataSourceInfo(
        kind: .bundled,
        document: "FO/CP/CRS Nº140 REV51 29JUN26",
        revision: "REV51",
        date: "2026-06-29",
        loadedAt: nil
    )

    private static let bundledResourceName = "wai_hotel_map_rev51"
    private static let cacheFileName = "wai_hotel_map_current.json"
    private static let bundledFallbackSource = OperationalDataDocumentSource(
        document: "FO/CP/CRS Nº140 REV51 29JUN26",
        revision: "REV51",
        date: "2026-06-29"
    )

    private init() {
        loadInitialHotels()
    }

    func hotel(for stationIATA: String) -> Hotel? {
        hotels.first { $0.iata == stationIATA }
    }

    @discardableResult
    func refreshRemoteData() async -> Bool {
        guard let dataset = await RemoteJSONLoader.refreshRemote(
            documentType: HotelDocument.self,
            remoteURL: RemoteDataConfiguration.hotelMapURL,
            cacheFileName: Self.cacheFileName
        ) else {
            return false
        }

        apply(dataset)
        return true
    }

    private func loadInitialHotels() {
        guard let dataset = RemoteJSONLoader.loadCachedOrBundled(
            documentType: HotelDocument.self,
            cacheFileName: Self.cacheFileName,
            bundledResourceName: Self.bundledResourceName,
            bundledFallbackSource: Self.bundledFallbackSource
        ) else {
            print("No valid hotel data available")
            return
        }

        apply(dataset)
    }

    private func apply(_ dataset: RemoteJSONDataset<HotelDocument>) {
        document = dataset.document
        hotels = dataset.document.hotels
        sourceInfo = dataset.sourceInfo
        print("Loaded \(dataset.document.hotels.count) hotels from \(dataset.sourceInfo.sourceLabel)")
    }
}
