import Foundation

struct StationData: Codable, OperationalDataDocument {
    let source: OperationalDataDocumentSource?
    let stations: [Station]

    var sourceInfo: OperationalDataDocumentSource? {
        source
    }

    var isValid: Bool {
        guard !stations.isEmpty else {
            return false
        }

        let iataCodes = stations.map(\.iata)
        guard Set(iataCodes).count == iataCodes.count else {
            return false
        }

        return stations.allSatisfy { station in
            station.iata.count == 3
            && !station.city.isEmpty
            && TimeZone(identifier: station.timeZone) != nil
            && station.defaultRule.isValid
            && station.alternatives.allSatisfy { $0.transportMinutes >= 0 && !$0.label.isEmpty }
            && (station.holidays ?? []).allSatisfy { $0.isValid }
        }
    }
}

@MainActor
final class DataService: ObservableObject {
    static let shared = DataService()

    @Published private(set) var stations: [Station] = []
    @Published private(set) var sourceInfo = OperationalDataSourceInfo(
        kind: .bundled,
        document: "FO/CP/CRS Nº141 REV73 13JUL26",
        revision: "REV73",
        date: "2026-07-13",
        loadedAt: nil
    )

    private static let bundledResourceName = "wai_transport_rules_rev73"
    private static let cacheFileName = "wai_transport_rules_current.json"
    private static let bundledFallbackSource = OperationalDataDocumentSource(
        document: "FO/CP/CRS Nº141 REV73 13JUL26",
        revision: "REV73",
        date: "2026-07-13"
    )

    private init() {
        loadInitialStations()
    }

    static func loadStations() -> [Station] {
        loadInitialDataset()?.document.stations ?? []
    }

    @discardableResult
    func refreshRemoteData() async -> Bool {
        guard let dataset = await RemoteJSONLoader.refreshRemote(
            documentType: StationData.self,
            remoteURL: RemoteDataConfiguration.transportRulesURL,
            cacheFileName: Self.cacheFileName
        ) else {
            return false
        }

        apply(dataset)
        return true
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
