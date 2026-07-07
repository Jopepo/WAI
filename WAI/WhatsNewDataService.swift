import Foundation

@MainActor
final class WhatsNewDataService: ObservableObject {
    static let shared = WhatsNewDataService()

    @Published private(set) var items: [WhatsNewItem] = []
    @Published private(set) var sourceInfo = OperationalDataSourceInfo(
        kind: .bundled,
        document: "WAI What's New",
        revision: "v2.2",
        date: "2026-07-07",
        loadedAt: nil
    )

    private static let bundledResourceName = "wai_whats_new_current"
    private static let cacheFileName = "wai_whats_new_current.json"
    private static let bundledFallbackSource = OperationalDataDocumentSource(
        document: "WAI What's New",
        revision: "v2.2",
        date: "2026-07-07"
    )

    private init() {
        loadInitialItems()
    }

    func refreshRemoteData() async {
        guard let dataset = await RemoteJSONLoader.refreshRemote(
            documentType: WhatsNewDocument.self,
            remoteURL: RemoteDataConfiguration.whatsNewURL,
            cacheFileName: Self.cacheFileName
        ) else {
            return
        }

        apply(dataset)
    }

    private func loadInitialItems() {
        guard let dataset = RemoteJSONLoader.loadCachedOrBundled(
            documentType: WhatsNewDocument.self,
            cacheFileName: Self.cacheFileName,
            bundledResourceName: Self.bundledResourceName,
            bundledFallbackSource: Self.bundledFallbackSource
        ) else {
            print("No valid what's new data available")
            return
        }

        apply(dataset)
    }

    private func apply(_ dataset: RemoteJSONDataset<WhatsNewDocument>) {
        guard !dataset.document.items.isEmpty else {
            print("Ignoring empty what's new data from \(dataset.sourceInfo.sourceLabel)")
            return
        }

        items = dataset.document.items
        sourceInfo = dataset.sourceInfo
        print("Loaded \(dataset.document.items.count) what's new items from \(dataset.sourceInfo.sourceLabel)")
    }
}
