#if DEBUG || WAI_UPGRADE_TEST_FIXTURE
import Foundation

enum WAI2UpgradeDebugFixture {
    enum FixtureError: Error {
        case missingBundledCache(String)
        case invalidCachedResponse
    }

    static let launchArgument = "--wai2-upgrade-test-fixture"
    static let environmentKey = "WAI2_UPGRADE_TEST_FIXTURE"
    static let seededKey = "wai.debug.upgradeFixtureSeeded"
    static let failureKey = "wai.debug.upgradeFixtureFailure"
    static let sentinelKey = "wai.debug.upgradeSentinel"
    static let unrelatedCacheFileName = "wai-upgrade-unrelated.cache"

    static func seed() throws {
        UserDefaults.standard.removeObject(forKey: failureKey)
        let calculationID = UUID(
            uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        ) ?? UUID()
        let referenceDate = Date(timeIntervalSince1970: 1_784_147_400)
        let calculation = CalculationHistoryItem(
            id: calculationID,
            createdAt: referenceDate,
            stationIATA: "CPH",
            stationCity: "Copenhagen",
            etdDate: referenceDate.addingTimeInterval(12 * 3_600),
            inputReference: .utc,
            inputTimeText: "08:00",
            pickupTimeText: "05:25",
            wakeupTimeText: "04:25",
            roomNumber: "742",
            appliedRuleLabel: "Upgrade fixture"
        )
        try UserDefaultsCalculationHistoryPersistence().save(
            CalculationHistorySnapshot(
                history: [calculation],
                lastCalculation: calculation
            ),
            for: nil
        )

        let stay = HotelStay(
            id: UUID(
                uuidString: "11111111-2222-3333-4444-555555555555"
            ) ?? UUID(),
            sourceCalculationID: calculationID,
            stationIATA: "CPH",
            hotelName: "Upgrade Test Hotel",
            city: "Copenhagen",
            country: "Denmark",
            roomNumber: "742",
            etdDate: calculation.etdDate,
            etdTimeText: "08:00",
            registeredAt: referenceDate,
            updatedAt: referenceDate
        )
        try UserDefaultsHotelStayPersistence().save(
            HotelStaySnapshot(stays: [stay]),
            for: nil
        )

        let defaults = UserDefaults.standard
        defaults.set("utc", forKey: "wai.timeInputReference")
        defaults.set("preserve", forKey: sentinelKey)

        let cachesDirectory = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        for fileName in WAILegacyOperationalCacheFiles.all {
            let resourceName = (fileName as NSString)
                .deletingPathExtension
            guard let bundledURL = Bundle.main.url(
                forResource: resourceName,
                withExtension: "json"
            ) else {
                throw FixtureError.missingBundledCache(fileName)
            }
            try Data(contentsOf: bundledURL).write(
                to: cachesDirectory.appendingPathComponent(fileName),
                options: .atomic
            )
        }
        try Data("preserve".utf8).write(
            to: cachesDirectory.appendingPathComponent(
                unrelatedCacheFileName
            ),
            options: .atomic
        )

        guard let cacheURL = URL(
            string: "https://example.com/wai-upgrade-fixture"
        ) else {
            throw FixtureError.invalidCachedResponse
        }
        let request = URLRequest(url: cacheURL)
        guard let response = HTTPURLResponse(
            url: cacheURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Cache-Control": "max-age=3600"]
        ) else {
            throw FixtureError.invalidCachedResponse
        }
        URLCache.shared.storeCachedResponse(
            CachedURLResponse(
                response: response,
                data: Data("legacy-cache".utf8)
            ),
            for: request
        )

        defaults.set(true, forKey: seededKey)
        _ = defaults.synchronize()
    }

    static func recordFailure(_ error: Error) {
        let defaults = UserDefaults.standard
        defaults.set(String(reflecting: error), forKey: failureKey)
        _ = defaults.synchronize()
    }
}
#endif
