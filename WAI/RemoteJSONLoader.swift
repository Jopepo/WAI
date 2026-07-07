import Foundation

enum OperationalDataSourceKind: String {
    case bundled = "Bundled"
    case cached = "Cached"
    case remote = "Remote"
}

struct OperationalDataSourceInfo {
    let kind: OperationalDataSourceKind
    let document: String
    let revision: String
    let date: String
    let loadedAt: Date?

    var sourceLabel: String {
        kind.rawValue
    }
}

protocol OperationalDataDocument {
    var sourceInfo: OperationalDataDocumentSource? { get }
}

struct OperationalDataDocumentSource: Codable {
    let document: String
    let revision: String
    let date: String
}

struct RemoteJSONDataset<Document: Decodable> {
    let document: Document
    let sourceInfo: OperationalDataSourceInfo
}

enum RemoteJSONLoader {
    static func loadCachedOrBundled<Document: Decodable & OperationalDataDocument>(
        documentType: Document.Type,
        cacheFileName: String,
        bundledResourceName: String,
        bundledFallbackSource: OperationalDataDocumentSource
    ) -> RemoteJSONDataset<Document>? {
        if let cached = loadCached(
            documentType: documentType,
            cacheFileName: cacheFileName
        ) {
            return cached
        }

        return loadBundled(
            documentType: documentType,
            resourceName: bundledResourceName,
            fallbackSource: bundledFallbackSource
        )
    }

    static func refreshRemote<Document: Decodable & OperationalDataDocument>(
        documentType: Document.Type,
        remoteURL: URL?,
        cacheFileName: String
    ) async -> RemoteJSONDataset<Document>? {
        guard let remoteURL else {
            return nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: remoteURL)

            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                print("Remote JSON request failed for \(remoteURL): HTTP \(httpResponse.statusCode)")
                return nil
            }

            let document = try JSONDecoder().decode(Document.self, from: data)
            try data.write(to: cacheURL(fileName: cacheFileName), options: [.atomic])

            return RemoteJSONDataset(
                document: document,
                sourceInfo: makeSourceInfo(
                    for: document,
                    kind: .remote,
                    loadedAt: Date()
                )
            )
        } catch {
            print("Remote JSON load failed for \(remoteURL): \(error)")
            return nil
        }
    }

    private static func loadCached<Document: Decodable & OperationalDataDocument>(
        documentType: Document.Type,
        cacheFileName: String
    ) -> RemoteJSONDataset<Document>? {
        do {
            let data = try Data(contentsOf: cacheURL(fileName: cacheFileName))
            let document = try JSONDecoder().decode(Document.self, from: data)

            return RemoteJSONDataset(
                document: document,
                sourceInfo: makeSourceInfo(
                    for: document,
                    kind: .cached,
                    loadedAt: nil
                )
            )
        } catch {
            return nil
        }
    }

    private static func loadBundled<Document: Decodable & OperationalDataDocument>(
        documentType: Document.Type,
        resourceName: String,
        fallbackSource: OperationalDataDocumentSource
    ) -> RemoteJSONDataset<Document>? {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "json") else {
            print("Bundled JSON file not found: \(resourceName).json")
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            let document = try JSONDecoder().decode(Document.self, from: data)

            return RemoteJSONDataset(
                document: document,
                sourceInfo: makeSourceInfo(
                    for: document,
                    kind: .bundled,
                    loadedAt: nil,
                    fallbackSource: fallbackSource
                )
            )
        } catch {
            print("Bundled JSON decode failed for \(resourceName).json: \(error)")
            return nil
        }
    }

    private static func makeSourceInfo(
        for document: OperationalDataDocument,
        kind: OperationalDataSourceKind,
        loadedAt: Date?,
        fallbackSource: OperationalDataDocumentSource? = nil
    ) -> OperationalDataSourceInfo {
        let source = document.sourceInfo ?? fallbackSource

        return OperationalDataSourceInfo(
            kind: kind,
            document: source?.document ?? "Unknown",
            revision: source?.revision ?? "Unknown",
            date: source?.date ?? "Unknown",
            loadedAt: loadedAt
        )
    }

    private static func cacheURL(fileName: String) throws -> URL {
        let directory = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        return directory.appendingPathComponent(fileName, conformingTo: .json)
    }
}

enum RemoteDataConfiguration {
    static var transportRulesURL: URL? {
        configuredURL(for: "WAIRemoteTransportRulesURL")
    }

    static var hotelMapURL: URL? {
        configuredURL(for: "WAIRemoteHotelMapURL")
    }

    private static func configuredURL(for key: String) -> URL? {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return URL(string: rawValue)
    }
}
