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
        guard OperationalDataFormat.isBoundedText(
                  document,
                  maximumBytes: 512
              ),
              OperationalDataFormat.isBoundedText(
                  revision,
                  maximumBytes: 128
              ),
              TransportTimeFormat.isValidISODate(date),
              (1...500).contains(hotels.count) else {
            return false
        }

        let iataCodes = hotels.map(\.iata)
        guard Set(iataCodes).count == iataCodes.count else {
            return false
        }

        return hotels.allSatisfy { hotel in
            OperationalDataFormat.isIdentifier(
                hotel.iata,
                length: 3,
                allowsDigits: false
            )
            && OperationalDataFormat.isIdentifier(
                hotel.icao,
                length: 4,
                allowsDigits: true
            )
            && OperationalDataFormat.isBoundedText(
                hotel.city,
                maximumBytes: 256
            )
            && OperationalDataFormat.isBoundedText(
                hotel.country,
                maximumBytes: 256
            )
            && OperationalDataFormat.isBoundedText(
                hotel.name,
                maximumBytes: 512
            )
            && OperationalDataFormat.isOptionalBoundedText(
                hotel.phone,
                maximumBytes: 512
            )
            && OperationalDataFormat.isOptionalBoundedText(
                hotel.email,
                maximumBytes: 512
            )
            && OperationalDataFormat.isOptionalBoundedText(
                hotel.fax,
                maximumBytes: 512
            )
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
        document: "FO/CP/CRS Nº140 REV52 20JUL26",
        revision: "REV52",
        date: "2026-07-20",
        loadedAt: nil
    )

    private static let bundledResourceName = "wai_hotel_map_rev52"
    private static let cacheFileName = WAILegacyOperationalCacheFiles.hotelMap
    private static let bundledFallbackSource = OperationalDataDocumentSource(
        document: "FO/CP/CRS Nº140 REV52 20JUL26",
        revision: "REV52",
        date: "2026-07-20"
    )
    private let mode: OperationalDataServiceMode

    init(mode: OperationalDataServiceMode = .legacyRemote) {
        self.mode = mode
        if mode == .legacyRemote {
            loadInitialHotels()
        }
    }

    func hotel(for stationIATA: String) -> Hotel? {
        hotels.first { $0.iata == stationIATA }
    }

    @discardableResult
    func refreshRemoteData() async -> Bool {
        guard mode == .legacyRemote else {
            return false
        }
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

    func applyProtected(
        document: HotelDocument,
        sourceInfo: OperationalDataSourceInfo
    ) {
        guard mode == .protectedRelease, document.isValid else {
            return
        }
        self.document = document
        hotels = document.hotels
        self.sourceInfo = sourceInfo
    }

    func clearProtectedData() {
        guard mode == .protectedRelease else {
            return
        }
        hotels = []
        document = nil
    }
}
