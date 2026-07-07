import Foundation

extension HotelDocument: OperationalDataDocument {
    var sourceInfo: OperationalDataDocumentSource? {
        OperationalDataDocumentSource(
            document: document,
            revision: revision,
            date: date
        )
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

    func refreshRemoteData() async {
        guard let dataset = await RemoteJSONLoader.refreshRemote(
            documentType: HotelDocument.self,
            remoteURL: RemoteDataConfiguration.hotelMapURL,
            cacheFileName: Self.cacheFileName
        ) else {
            return
        }

        apply(dataset)
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
