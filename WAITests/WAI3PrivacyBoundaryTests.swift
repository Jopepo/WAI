import Foundation
import Testing
import UIKit
@testable import WAI

struct WAI3PrivacyBoundaryTests {
    private let userID = UUID(
        uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    )!

    @Test func secureCoordinatorHasNoBundledFallbackByDefault() async throws {
        let package = try makePrivacyBoundaryPackage()
        let cache = try PrivacyBoundaryCacheFixture()
        let coordinator = OperationalReleaseCoordinator(
            remote: PrivacyBoundaryRemote(package: package),
            cache: cache.cache,
            currentAppVersion: "3.0"
        )

        await #expect(
            throws: OperationalReleaseCoordinatorError.noValidatedLocalRelease
        ) {
            _ = try await coordinator.loadBestAvailable(for: userID)
        }
    }

    @Test func legacyPersonalDataCanBeIncludedInSecureWipe() throws {
        let suiteName = "WAI3PrivacyBoundaryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("history".utf8), forKey: "wai.calculationHistory")
        defaults.set(Data("last".utf8), forKey: "wai.lastCalculation")
        defaults.set(Data("stays".utf8), forKey: "wai.hotelStays")
        let group = WAISensitiveDataStoreGroup([
            UserDefaultsCalculationHistoryPersistence(defaults: defaults),
            UserDefaultsHotelStayPersistence(defaults: defaults)
        ])

        try group.clear()

        #expect(defaults.data(forKey: "wai.calculationHistory") == nil)
        #expect(defaults.data(forKey: "wai.lastCalculation") == nil)
        #expect(defaults.data(forKey: "wai.hotelStays") == nil)
    }

    @Test @MainActor
    func privacyShieldCoversTheWholeWindowOnlyWhenRequested() {
        let window = UIWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844)
        )
        let controller = WAI3PrivacyShieldWindowController()
        controller.attach(to: window)

        controller.setVisible(true)

        #expect(controller.isShieldVisible)
        #expect(
            window.subviews.last?.accessibilityIdentifier
                == "wai3.privacyShieldWindow"
        )

        controller.setVisible(false)

        #expect(!controller.isShieldVisible)
        #expect(
            !window.subviews.contains {
                $0.accessibilityIdentifier == "wai3.privacyShieldWindow"
            }
        )
    }
}

private final class PrivacyBoundaryRemote: WAIPrivateOperationalDataServing {
    let package: OperationalReleasePackage

    init(package: OperationalReleasePackage) {
        self.package = package
    }

    func fetchActiveRelease(
        session: WAIAuthSession
    ) async throws -> OperationalReleaseManifest {
        package.manifest
    }

    func downloadDataset(
        _ descriptor: OperationalDatasetDescriptor,
        session: WAIAuthSession
    ) async throws -> Data {
        try #require(package.payloads[descriptor.key])
    }
}

private struct PrivacyBoundaryCacheFixture {
    let directory: URL
    let fileURL: URL
    let cache: ProtectedOperationalReleaseCache

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        fileURL = directory.appendingPathComponent("release.cache")
        cache = ProtectedOperationalReleaseCache(
            fileURL: fileURL,
            keyStore: PrivacyBoundaryKeyStore()
        )
    }
}

private final class PrivacyBoundaryKeyStore: OperationalReleaseKeyStore {
    func loadOrCreateKeyData() throws -> Data {
        Data(repeating: 0xA5, count: 32)
    }

    func deleteKey() throws {}
}

private func makePrivacyBoundaryPackage() throws -> OperationalReleasePackage {
    let bundled = try BundledOperationalReleaseProvider(bundle: .main).load()
    return bundled
}
