import Foundation
import Testing
@testable import WAI

struct WAI3LegacyDataSanitizerTests {
    @Test func secureLaunchRemovesOnlyLegacySensitiveState() throws {
        let suiteName = "WAI3LegacyDataSanitizerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let urlCache = URLCache(
            memoryCapacity: 1_024 * 1_024,
            diskCapacity: 0
        )
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }

        defaults.set(Data("history".utf8), forKey: "wai.calculationHistory")
        defaults.set(Data("last".utf8), forKey: "wai.lastCalculation")
        defaults.set(Data("stays".utf8), forKey: "wai.hotelStays")
        defaults.set("utc", forKey: "wai.timeInputReference")

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        for fileName in WAILegacyOperationalCacheFiles.all {
            try Data("legacy-json".utf8).write(
                to: directory.appendingPathComponent(fileName)
            )
        }
        let unrelatedURL = directory.appendingPathComponent("unrelated.cache")
        try Data("keep".utf8).write(to: unrelatedURL)

        let request = URLRequest(
            url: URL(string: "https://example.com/legacy.json")!
        )
        let response = try #require(
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Cache-Control": "max-age=3600"]
            )
        )
        urlCache.storeCachedResponse(
            CachedURLResponse(
                response: response,
                data: Data("cached-json".utf8)
            ),
            for: request
        )

        try WAI3LegacyDataSanitizer(
            defaults: defaults,
            cachesDirectory: directory,
            urlCache: urlCache
        ).sanitize()

        #expect(defaults.data(forKey: "wai.calculationHistory") == nil)
        #expect(defaults.data(forKey: "wai.lastCalculation") == nil)
        #expect(defaults.data(forKey: "wai.hotelStays") == nil)
        #expect(defaults.string(forKey: "wai.timeInputReference") == "utc")
        for fileName in WAILegacyOperationalCacheFiles.all {
            #expect(
                !FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(fileName).path
                )
            )
        }
        #expect(FileManager.default.fileExists(atPath: unrelatedURL.path))
        #expect(urlCache.cachedResponse(for: request) == nil)
    }
}
