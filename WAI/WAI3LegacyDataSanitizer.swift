import Foundation

struct WAI3LegacyDataSanitizer {
    private let personalDataStores: WAISensitiveDataStoreGroup
    private let cachesDirectory: URL
    private let fileManager: FileManager
    private let urlCache: URLCache

    init(
        defaults: UserDefaults,
        cachesDirectory: URL,
        fileManager: FileManager = .default,
        urlCache: URLCache = .shared
    ) {
        personalDataStores = WAISensitiveDataStoreGroup([
            UserDefaultsCalculationHistoryPersistence(defaults: defaults),
            UserDefaultsHotelStayPersistence(defaults: defaults)
        ])
        self.cachesDirectory = cachesDirectory
        self.fileManager = fileManager
        self.urlCache = urlCache
    }

    static func production() throws -> WAI3LegacyDataSanitizer {
        let cachesDirectory = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return WAI3LegacyDataSanitizer(
            defaults: .standard,
            cachesDirectory: cachesDirectory
        )
    }

    func sanitize() throws {
        var firstError: Error?

        do {
            try personalDataStores.clear()
        } catch {
            firstError = error
        }

        for fileName in WAILegacyOperationalCacheFiles.all {
            let fileURL = cachesDirectory.appendingPathComponent(fileName)
            guard fileManager.fileExists(atPath: fileURL.path) else {
                continue
            }
            do {
                try fileManager.removeItem(at: fileURL)
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        urlCache.removeAllCachedResponses()

        if let firstError {
            throw firstError
        }
    }
}
