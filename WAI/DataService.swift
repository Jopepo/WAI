import Foundation

struct StationData: Codable, OperationalDataDocument {
    let source: OperationalDataDocumentSource?
    let stations: [Station]

    var sourceInfo: OperationalDataDocumentSource? {
        source
    }
}

@MainActor
final class DataService: ObservableObject {
    static let shared = DataService()

    @Published private(set) var stations: [Station] = []
    @Published private(set) var sourceInfo = OperationalDataSourceInfo(
        kind: .bundled,
        document: "FO/CP/CRS Nº141 REV72 06JUL26",
        revision: "REV72",
        date: "2026-07-06",
        loadedAt: nil
    )

    private static let bundledResourceName = "wai_transport_rules_rev72"
    private static let cacheFileName = "wai_transport_rules_current.json"
    private static let bundledFallbackSource = OperationalDataDocumentSource(
        document: "FO/CP/CRS Nº141 REV72 06JUL26",
        revision: "REV72",
        date: "2026-07-06"
    )

    private init() {
        loadInitialStations()
    }

    static func loadStations() -> [Station] {
        loadInitialDataset()?.document.stations ?? []
    }

    func refreshRemoteData() async {
        guard let dataset = await RemoteJSONLoader.refreshRemote(
            documentType: StationData.self,
            remoteURL: RemoteDataConfiguration.transportRulesURL,
            cacheFileName: Self.cacheFileName
        ) else {
            return
        }

        apply(dataset)
    }

    private func loadInitialStations() {
        guard let dataset = Self.loadInitialDataset() else {
            print("No valid transport data available")
            return
        }

        apply(dataset)
    }

    private func apply(_ dataset: RemoteJSONDataset<StationData>) {
        stations = dataset.document.stations
        sourceInfo = dataset.sourceInfo
        print("Loaded \(dataset.document.stations.count) stations from \(dataset.sourceInfo.sourceLabel)")
    }

    private static func loadInitialDataset() -> RemoteJSONDataset<StationData>? {
        RemoteJSONLoader.loadCachedOrBundled(
            documentType: StationData.self,
            cacheFileName: cacheFileName,
            bundledResourceName: bundledResourceName,
            bundledFallbackSource: bundledFallbackSource
        )
    }
}
