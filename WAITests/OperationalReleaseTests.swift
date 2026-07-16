import Foundation
import Testing
@testable import WAI

struct OperationalReleaseTests {
    @Test func validatesCurrentOperationalDocumentsAsOneRelease() throws {
        let package = try makeCurrentPackage()

        try OperationalReleaseValidator.validatePackage(
            manifest: package.manifest,
            payloads: package.payloads
        )
    }

    @Test func rejectsChangedPayloadAfterManifestPreparation() throws {
        let package = try makeCurrentPackage()
        var payloads = package.payloads
        payloads[.hotelMap]?.append(0x20)

        #expect(throws: OperationalReleaseValidationError.self) {
            try OperationalReleaseValidator.validatePackage(
                manifest: package.manifest,
                payloads: payloads
            )
        }
    }

    @Test func rejectsNonASCIIDigest() throws {
        let package = try makeCurrentPackage()
        var descriptors = package.manifest.datasets
        let first = try #require(descriptors.first)
        let nonASCIIDigest = String(repeating: "\u{0660}", count: 64)
        descriptors[0] = OperationalDatasetDescriptor(
            key: first.key,
            schemaVersion: first.schemaVersion,
            source: first.source,
            objectPath: "\(first.key.rawValue)/\(nonASCIIDigest).json",
            sha256: nonASCIIDigest,
            byteCount: first.byteCount
        )
        let invalid = OperationalReleaseManifest(
            contractVersion: package.manifest.contractVersion,
            generation: package.manifest.generation,
            minimumAppVersion: package.manifest.minimumAppVersion,
            datasets: descriptors
        )

        #expect(throws: OperationalReleaseValidationError.invalidDigest(first.key)) {
            try OperationalReleaseValidator.validateManifest(invalid)
        }
    }

    @Test func rejectsIncompleteRelease() throws {
        let package = try makeCurrentPackage()
        let manifest = OperationalReleaseManifest(
            contractVersion: package.manifest.contractVersion,
            generation: package.manifest.generation,
            minimumAppVersion: package.manifest.minimumAppVersion,
            datasets: Array(package.manifest.datasets.dropLast())
        )

        #expect(throws: OperationalReleaseValidationError.incompleteDatasetSet) {
            try OperationalReleaseValidator.validateManifest(manifest)
        }
    }

    @Test func rejectsGenerationRollback() throws {
        let package = try makeCurrentPackage(generation: 9)
        let older = OperationalReleaseManifest(
            contractVersion: package.manifest.contractVersion,
            generation: 8,
            minimumAppVersion: package.manifest.minimumAppVersion,
            datasets: package.manifest.datasets
        )

        #expect(
            throws: OperationalReleaseValidationError.rollback(current: 9, candidate: 8)
        ) {
            try OperationalReleaseValidator.validateCandidate(
                older,
                replacing: package.manifest
            )
        }
    }

    @Test func semanticAppVersionComparisonNormalizesPatchComponent() throws {
        let package = try makeCurrentPackage()

        try OperationalReleaseValidator.validateCompatibility(
            package.manifest,
            currentAppVersion: "3.0.0"
        )

        #expect(
            throws: OperationalReleaseValidationError.minimumAppVersionNotMet(
                required: "3.0",
                current: "2.9.9"
            )
        ) {
            try OperationalReleaseValidator.validateCompatibility(
                package.manifest,
                currentAppVersion: "2.9.9"
            )
        }
    }

    @Test func rejectsVersionComponentsOutsideBackendContract() throws {
        let package = try makeCurrentPackage()
        let version = "3.1234567890"
        let invalid = OperationalReleaseManifest(
            contractVersion: package.manifest.contractVersion,
            generation: package.manifest.generation,
            minimumAppVersion: version,
            datasets: package.manifest.datasets
        )

        #expect(
            throws: OperationalReleaseValidationError
                .invalidMinimumAppVersion(version)
        ) {
            try OperationalReleaseValidator.validateManifest(invalid)
        }
    }

    @Test func rejectsConflictingReleaseWithSameGeneration() throws {
        let package = try makeCurrentPackage(generation: 4)
        var descriptors = package.manifest.datasets
        let first = try #require(descriptors.first)
        descriptors[0] = OperationalDatasetDescriptor(
            key: first.key,
            schemaVersion: first.schemaVersion,
            source: first.source,
            objectPath: first.objectPath,
            sha256: first.sha256,
            byteCount: first.byteCount - 1
        )
        let conflicting = OperationalReleaseManifest(
            contractVersion: package.manifest.contractVersion,
            generation: package.manifest.generation,
            minimumAppVersion: package.manifest.minimumAppVersion,
            datasets: descriptors
        )

        #expect(throws: OperationalReleaseValidationError.generationConflict(4)) {
            try OperationalReleaseValidator.validateCandidate(
                conflicting,
                replacing: package.manifest
            )
        }
    }
}

struct ProtectedOperationalReleaseCacheTests {
    @Test func encryptedCacheRoundTripsValidatedRelease() throws {
        let package = try makeCurrentPackage()
        let fixture = try CacheFixture()
        let ownerUserID = UUID()

        try fixture.cache.save(
            ownerUserID: ownerUserID,
            manifest: package.manifest,
            payloads: package.payloads
        )
        let cachedRelease = try fixture.cache.load(for: ownerUserID)
        let loaded = try #require(cachedRelease)

        #expect(loaded.manifest == package.manifest)
        #expect(loaded.payloads == package.payloads)
        let rawCache = try Data(contentsOf: fixture.fileURL)
        let transportPayload = try #require(package.payloads[.transportRules])
        #expect(rawCache.range(of: transportPayload) == nil)
    }

    @Test func encryptedCacheRejectsTampering() throws {
        let package = try makeCurrentPackage()
        let fixture = try CacheFixture()
        let ownerUserID = UUID()
        try fixture.cache.save(
            ownerUserID: ownerUserID,
            manifest: package.manifest,
            payloads: package.payloads
        )

        var encrypted = try Data(contentsOf: fixture.fileURL)
        encrypted[encrypted.startIndex] ^= 0x01
        try encrypted.write(to: fixture.fileURL, options: .atomic)

        var didRejectTamperedCache = false
        do {
            _ = try fixture.cache.load(for: ownerUserID)
        } catch {
            didRejectTamperedCache = true
        }
        #expect(didRejectTamperedCache)
    }

    @Test func oversizedEncryptedCacheIsRejectedBeforeReading() throws {
        let fixture = try CacheFixture()
        try FileManager.default.createDirectory(
            at: fixture.directory,
            withIntermediateDirectories: true
        )
        try Data(
            repeating: 0xA5,
            count: ProtectedOperationalReleaseCache.maximumFileBytes + 1
        ).write(to: fixture.fileURL)

        #expect(throws: ProtectedOperationalReleaseCacheError.fileTooLarge) {
            _ = try fixture.cache.load(for: UUID())
        }
    }

    @Test func clearDeletesCacheAndEncryptionKey() throws {
        let package = try makeCurrentPackage()
        let fixture = try CacheFixture()
        try fixture.cache.save(
            ownerUserID: UUID(),
            manifest: package.manifest,
            payloads: package.payloads
        )

        try fixture.cache.clear()

        #expect(!FileManager.default.fileExists(atPath: fixture.fileURL.path))
        #expect(fixture.keyStore.wasDeleted)
    }

    @Test func clearPreventsAnEarlierRefreshFromRecreatingCache() throws {
        let package = try makeCurrentPackage()
        let fixture = try CacheFixture()
        let ownerUserID = UUID()
        let staleToken = fixture.cache.makeRefreshToken()

        try fixture.cache.clear()

        #expect(
            throws: ProtectedOperationalReleaseCacheError.operationInvalidated
        ) {
            try fixture.cache.save(
                ownerUserID: ownerUserID,
                manifest: package.manifest,
                payloads: package.payloads,
                refreshToken: staleToken
            )
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.fileURL.path))

        try fixture.cache.save(
            ownerUserID: ownerUserID,
            manifest: package.manifest,
            payloads: package.payloads,
            refreshToken: fixture.cache.makeRefreshToken()
        )
        #expect(try fixture.cache.load(for: ownerUserID) != nil)
    }

    @Test func encryptedCacheIsBoundToApprovedUser() throws {
        let package = try makeCurrentPackage()
        let fixture = try CacheFixture()
        try fixture.cache.save(
            ownerUserID: UUID(),
            manifest: package.manifest,
            payloads: package.payloads
        )

        #expect(throws: ProtectedOperationalReleaseCacheError.ownerMismatch) {
            _ = try fixture.cache.load(for: UUID())
        }
    }
}

private struct OperationalReleasePackageFixture {
    let manifest: OperationalReleaseManifest
    let payloads: [OperationalDatasetKey: Data]
}

private func makeCurrentPackage(
    generation: Int = 1
) throws -> OperationalReleasePackageFixture {
    let transport = try bundledData(named: "wai_transport_rules_current")
    let hotel = try bundledData(named: "wai_hotel_map_current")
    let whatsNew = try bundledData(named: "wai_whats_new_current")
    let payloads: [OperationalDatasetKey: Data] = [
        .transportRules: transport,
        .hotelMap: hotel,
        .whatsNew: whatsNew
    ]

    let transportDocument = try JSONDecoder().decode(StationData.self, from: transport)
    let hotelDocument = try JSONDecoder().decode(HotelDocument.self, from: hotel)
    let whatsNewDocument = try JSONDecoder().decode(WhatsNewDocument.self, from: whatsNew)
    let hotelSource = try #require(hotelDocument.sourceInfo)
    let transportSource = try #require(transportDocument.sourceInfo)
    let whatsNewSource = try #require(whatsNewDocument.sourceInfo)

    let descriptors = [
        descriptor(
            key: .hotelMap,
            schemaVersion: "1.0",
            source: hotelSource,
            data: hotel
        ),
        descriptor(
            key: .transportRules,
            schemaVersion: "4.2",
            source: transportSource,
            data: transport
        ),
        descriptor(
            key: .whatsNew,
            schemaVersion: "1.0",
            source: whatsNewSource,
            data: whatsNew
        )
    ]

    return OperationalReleasePackageFixture(
        manifest: OperationalReleaseManifest(
            contractVersion: 1,
            generation: generation,
            minimumAppVersion: "3.0",
            datasets: descriptors
        ),
        payloads: payloads
    )
}

private func descriptor(
    key: OperationalDatasetKey,
    schemaVersion: String,
    source: OperationalDataDocumentSource,
    data: Data
) -> OperationalDatasetDescriptor {
    let digest = OperationalReleaseValidator.sha256(data)
    return OperationalDatasetDescriptor(
        key: key,
        schemaVersion: schemaVersion,
        source: OperationalReleaseSource(
            document: source.document,
            revision: source.revision,
            date: source.date
        ),
        objectPath: "\(key.rawValue)/\(digest).json",
        sha256: digest,
        byteCount: data.count
    )
}

private func bundledData(named resourceName: String) throws -> Data {
    let url = try #require(Bundle.main.url(forResource: resourceName, withExtension: "json"))
    return try Data(contentsOf: url)
}

private final class InMemoryOperationalReleaseKeyStore: OperationalReleaseKeyStore {
    let key = Data(repeating: 0xA5, count: 32)
    private(set) var wasDeleted = false

    func loadOrCreateKeyData() throws -> Data {
        key
    }

    func deleteKey() throws {
        wasDeleted = true
    }
}

private struct CacheFixture {
    let directory: URL
    let fileURL: URL
    let keyStore: InMemoryOperationalReleaseKeyStore
    let cache: ProtectedOperationalReleaseCache

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        fileURL = directory.appendingPathComponent("release.cache")
        keyStore = InMemoryOperationalReleaseKeyStore()
        cache = ProtectedOperationalReleaseCache(
            fileURL: fileURL,
            keyStore: keyStore
        )
    }
}
