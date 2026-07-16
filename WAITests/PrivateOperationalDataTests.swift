import Foundation
import Testing
@testable import WAI

struct SupabaseWAIBackendClientTests {
    private let baseURL = URL(string: "https://abcdefghijklmnopqrst.supabase.co")!
    private let publishableKey = "sb_publishable_12345678901234567890"
    private let userID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    @Test func configurationAllowsOnlyExactSupabaseHTTPSHost() throws {
        let configuration = try WAIBackendConfiguration(
            baseURL: baseURL,
            publishableKey: publishableKey
        )

        #expect(configuration.baseURL == baseURL)
        #expect(configuration.publishableKey == publishableKey)

        let invalidURLs = [
            "http://abcdefghijklmnopqrst.supabase.co",
            "https://abcdefghijklmnopqrst.supabase.co/other",
            "https://abcdefghijklmnopqrst.supabase.co@example.com",
            "https://raw.githubusercontent.com/Jopepo/WAI/main/data.json"
        ]
        for value in invalidURLs {
            let url = try #require(URL(string: value))
            #expect(throws: WAIBackendConfigurationError.invalidURL) {
                _ = try WAIBackendConfiguration(
                    baseURL: url,
                    publishableKey: publishableKey
                )
            }
        }
    }

    @Test func activeReleaseUsesAuthenticatedPostgRESTRequest() async throws {
        let package = try remotePackage(generation: 7)
        let transport = BackendTransportStub(
            responses: [
                .init(data: try releaseResponseData(package.manifest), statusCode: 200)
            ]
        )
        let client = try makeClient(transport: transport)

        let manifest = try await client.fetchActiveRelease(session: session())

        #expect(manifest == package.manifest)
        let request = try #require(transport.requests.only)
        #expect(request.url?.path == "/rest/v1/wai_operational_releases")
        #expect(request.url?.query?.contains("active=eq.true") == true)
        #expect(request.value(forHTTPHeaderField: "apikey") == publishableKey)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(
            request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token"
        )
    }

    @Test func privateDatasetUsesAuthenticatedStorageEndpoint() async throws {
        let package = try remotePackage(generation: 2)
        let descriptor = try #require(
            package.manifest.datasets.first { $0.key == .hotelMap }
        )
        let payload = try #require(package.payloads[.hotelMap])
        let transport = BackendTransportStub(
            responses: [.init(data: payload, statusCode: 200)]
        )
        let client = try makeClient(transport: transport)

        let downloaded = try await client.downloadDataset(
            descriptor,
            session: session()
        )

        #expect(downloaded == payload)
        let request = try #require(transport.requests.only)
        #expect(
            request.url?.path ==
            "/storage/v1/object/authenticated/wai-operational-data/\(descriptor.objectPath)"
        )
        #expect(
            request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token"
        )
    }

    @Test func profileResponseMustBelongToAuthenticatedUser() async throws {
        let profileJSON = """
        [{
          "id": "\(userID.uuidString.lowercased())",
          "approval_code": "A1B2C3D4E5F6",
          "access_status": "approved",
          "created_at": "2026-07-15T08:00:00Z",
          "approved_at": "2026-07-15T09:00:00.123Z",
          "revoked_at": null
        }]
        """
        let transport = BackendTransportStub(
            responses: [
                .init(data: Data(profileJSON.utf8), statusCode: 200)
            ]
        )
        let client = try makeClient(transport: transport)

        let profile = try await client.fetchProfile(session: session())

        #expect(profile.id == userID)
        #expect(profile.accessStatus == .approved)
        #expect(profile.isValid)
    }

    @Test func forbiddenResponseIsNeverDecodedAsOperationalData() async throws {
        let transport = BackendTransportStub(
            responses: [.init(data: Data("{}".utf8), statusCode: 403)]
        )
        let client = try makeClient(transport: transport)

        await #expect(throws: WAIPrivateBackendError.forbidden) {
            _ = try await client.fetchActiveRelease(session: session())
        }
    }

    @Test func privateNetworkSessionHasNoPersistentWebState() {
        let configuration = WAIPrivateNetworkSession.makeConfiguration()

        #expect(
            configuration.requestCachePolicy
            == .reloadIgnoringLocalCacheData
        )
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.timeoutIntervalForRequest == 20)
        #expect(configuration.timeoutIntervalForResource == 45)
    }

    @Test func privateResponseBufferRejectsOversizedContentLength() {
        #expect(throws: WAIPrivateBackendError.responseTooLarge) {
            _ = try WAIPrivateHTTPResponseBuffer(
                expectedContentLength: 3,
                maximumBytes: 2
            )
        }
    }

    @Test func privateResponseBufferStopsUnknownLengthStreamAtLimit() throws {
        var buffer = try WAIPrivateHTTPResponseBuffer(
            expectedContentLength: -1,
            maximumBytes: 2
        )

        try buffer.append(0x01)
        try buffer.append(0x02)
        #expect(buffer.data == Data([0x01, 0x02]))
        #expect(throws: WAIPrivateBackendError.responseTooLarge) {
            try buffer.append(0x03)
        }
    }

    private func makeClient(
        transport: BackendTransportStub
    ) throws -> SupabaseWAIBackendClient {
        SupabaseWAIBackendClient(
            configuration: try WAIBackendConfiguration(
                baseURL: baseURL,
                publishableKey: publishableKey
            ),
            transport: transport
        )
    }

    private func session() -> WAIAuthSession {
        WAIAuthSession(
            userID: userID,
            accessToken: "access-token",
            refreshToken: "refresh-token",
            expiresAt: Date(timeIntervalSince1970: 1_784_116_000)
        )
    }
}

struct OperationalReleaseCoordinatorTests {
    private let userID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    @Test func completeRemoteReleaseReplacesCacheAtomically() async throws {
        let package = try remotePackage(generation: 8)
        let remote = StubPrivateOperationalDataService(package: package)
        let cache = try CoordinatorCacheFixture()
        let coordinator = OperationalReleaseCoordinator(
            remote: remote,
            cache: cache.cache,
            bundled: StubBundledReleaseProvider(package: package),
            currentAppVersion: "3.0"
        )

        let selection = try await coordinator.refresh(
            for: session(),
            refreshToken: cache.cache.makeRefreshToken()
        )

        #expect(selection.origin == .remote)
        #expect(selection.package == package)
        #expect(Set(remote.downloadedKeys) == Set(OperationalDatasetKey.allCases))
        let cachedRelease = try cache.cache.load(for: userID)
        let cached = try #require(cachedRelease)
        #expect(cached.manifest == package.manifest)
        #expect(cached.payloads == package.payloads)
    }

    @Test func changedPayloadCannotReplaceEarlierGoodCache() async throws {
        let earlier = try remotePackage(generation: 4)
        let candidate = try remotePackage(generation: 5)
        var changedPayloads = candidate.payloads
        changedPayloads[.transportRules]?.append(0x20)
        let remote = StubPrivateOperationalDataService(
            package: OperationalReleasePackage(
                manifest: candidate.manifest,
                payloads: changedPayloads
            )
        )
        let cache = try CoordinatorCacheFixture()
        try cache.cache.save(
            ownerUserID: userID,
            manifest: earlier.manifest,
            payloads: earlier.payloads
        )
        let coordinator = OperationalReleaseCoordinator(
            remote: remote,
            cache: cache.cache,
            bundled: StubBundledReleaseProvider(package: earlier),
            currentAppVersion: "3.0"
        )

        var didRejectCandidate = false
        do {
            _ = try await coordinator.refresh(
                for: session(),
                refreshToken: cache.cache.makeRefreshToken()
            )
        } catch is OperationalReleaseValidationError {
            didRejectCandidate = true
        }

        #expect(didRejectCandidate)
        let persistedRelease = try cache.cache.load(for: userID)
        let stillCached = try #require(persistedRelease)
        #expect(stillCached.manifest == earlier.manifest)
        #expect(stillCached.payloads == earlier.payloads)
    }

    @Test func remoteGenerationCannotRollBackSecureCache() async throws {
        let cachedPackage = try remotePackage(generation: 9)
        let olderPackage = try remotePackage(generation: 8)
        let cache = try CoordinatorCacheFixture()
        try cache.cache.save(
            ownerUserID: userID,
            manifest: cachedPackage.manifest,
            payloads: cachedPackage.payloads
        )
        let coordinator = OperationalReleaseCoordinator(
            remote: StubPrivateOperationalDataService(package: olderPackage),
            cache: cache.cache,
            bundled: StubBundledReleaseProvider(package: cachedPackage),
            currentAppVersion: "3.0"
        )

        await #expect(
            throws: OperationalReleaseValidationError.rollback(
                current: 9,
                candidate: 8
            )
        ) {
            _ = try await coordinator.refresh(
                for: session(),
                refreshToken: cache.cache.makeRefreshToken()
            )
        }
    }

    @Test func releaseRequiringNewerAppIsRejectedBeforeDownload() async throws {
        let package = try remotePackage(
            generation: 3,
            minimumAppVersion: "3.1"
        )
        let remote = StubPrivateOperationalDataService(package: package)
        let cache = try CoordinatorCacheFixture()
        let coordinator = OperationalReleaseCoordinator(
            remote: remote,
            cache: cache.cache,
            bundled: StubBundledReleaseProvider(package: package),
            currentAppVersion: "3.0"
        )

        await #expect(
            throws: OperationalReleaseValidationError.minimumAppVersionNotMet(
                required: "3.1",
                current: "3.0"
            )
        ) {
            _ = try await coordinator.refresh(
                for: session(),
                refreshToken: cache.cache.makeRefreshToken()
            )
        }
        #expect(remote.downloadedKeys.isEmpty)
    }

    @Test func invalidatedRefreshCannotReachRemoteOrRecreateCache() async throws {
        let package = try remotePackage(generation: 3)
        let remote = StubPrivateOperationalDataService(package: package)
        let cache = try CoordinatorCacheFixture()
        let coordinator = OperationalReleaseCoordinator(
            remote: remote,
            cache: cache.cache,
            bundled: StubBundledReleaseProvider(package: package),
            currentAppVersion: "3.0"
        )
        let staleToken = cache.cache.makeRefreshToken()
        try cache.cache.clear()

        await #expect(
            throws: OperationalReleaseCoordinatorError.operationInvalidated
        ) {
            _ = try await coordinator.refresh(
                for: session(),
                refreshToken: staleToken
            )
        }

        #expect(remote.fetchCount == 0)
        #expect(remote.downloadedKeys.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: cache.fileURL.path))
    }

    @Test func cacheForAnotherUserFallsBackToBundledData() async throws {
        let package = try remotePackage(generation: 2)
        let cache = try CoordinatorCacheFixture()
        try cache.cache.save(
            ownerUserID: UUID(),
            manifest: package.manifest,
            payloads: package.payloads
        )
        let coordinator = OperationalReleaseCoordinator(
            remote: StubPrivateOperationalDataService(package: package),
            cache: cache.cache,
            bundled: StubBundledReleaseProvider(package: package),
            currentAppVersion: "3.0"
        )

        let selection = try await coordinator.loadBestAvailable(for: userID)

        #expect(selection.origin == .bundled)
        #expect(selection.package == package)
        #expect(!FileManager.default.fileExists(atPath: cache.fileURL.path))
    }

    @Test func unclearedInvalidCacheFailsAsSecureStorageError() async throws {
        let package = try remotePackage(generation: 2)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("release.cache")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data([0x00]).write(to: fileURL)
        let cache = ProtectedOperationalReleaseCache(
            fileURL: fileURL,
            keyStore: FailingDeleteCoordinatorCacheKeyStore()
        )
        let coordinator = OperationalReleaseCoordinator(
            remote: StubPrivateOperationalDataService(package: package),
            cache: cache,
            bundled: StubBundledReleaseProvider(package: package),
            currentAppVersion: "3.0"
        )

        await #expect(
            throws: OperationalReleaseCoordinatorError.secureStorage
        ) {
            _ = try await coordinator.loadBestAvailable(for: userID)
        }
    }

    private func session() -> WAIAuthSession {
        WAIAuthSession(
            userID: userID,
            accessToken: "access-token",
            refreshToken: "refresh-token",
            expiresAt: Date(timeIntervalSince1970: 1_784_116_000)
        )
    }
}

private struct BackendStubResponse {
    let data: Data
    let statusCode: Int
}

private final class BackendTransportStub: WAIHTTPTransport {
    private var responses: [BackendStubResponse]
    private(set) var requests: [URLRequest] = []

    init(responses: [BackendStubResponse]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else {
            throw URLError(.badServerResponse)
        }
        let next = responses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: next.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (next.data, response)
    }
}

private final class StubPrivateOperationalDataService: WAIPrivateOperationalDataServing {
    let package: OperationalReleasePackage
    private(set) var fetchCount = 0
    private(set) var downloadedKeys: [OperationalDatasetKey] = []

    init(package: OperationalReleasePackage) {
        self.package = package
    }

    func fetchActiveRelease(
        session: WAIAuthSession
    ) async throws -> OperationalReleaseManifest {
        fetchCount += 1
        return package.manifest
    }

    func downloadDataset(
        _ descriptor: OperationalDatasetDescriptor,
        session: WAIAuthSession
    ) async throws -> Data {
        downloadedKeys.append(descriptor.key)
        guard let data = package.payloads[descriptor.key] else {
            throw WAIPrivateBackendError.notFound
        }
        return data
    }
}

private struct StubBundledReleaseProvider: BundledOperationalReleaseProviding {
    let package: OperationalReleasePackage

    func load() throws -> OperationalReleasePackage {
        package
    }
}

private final class CoordinatorCacheKeyStore: OperationalReleaseKeyStore {
    let key = Data(repeating: 0x5A, count: 32)

    func loadOrCreateKeyData() throws -> Data {
        key
    }

    func deleteKey() throws { }
}

private final class FailingDeleteCoordinatorCacheKeyStore:
    OperationalReleaseKeyStore {
    func loadOrCreateKeyData() throws -> Data {
        Data(repeating: 0x5A, count: 32)
    }

    func deleteKey() throws {
        throw OperationalReleaseKeyStoreError.keychain(-1)
    }
}

private struct CoordinatorCacheFixture {
    let fileURL: URL
    let cache: ProtectedOperationalReleaseCache

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        fileURL = directory.appendingPathComponent("release.cache")
        cache = ProtectedOperationalReleaseCache(
            fileURL: fileURL,
            keyStore: CoordinatorCacheKeyStore()
        )
    }
}

private func remotePackage(
    generation: Int,
    minimumAppVersion: String = "3.0"
) throws -> OperationalReleasePackage {
    let bundled = try BundledOperationalReleaseProvider(bundle: .main).load()
    return OperationalReleasePackage(
        manifest: OperationalReleaseManifest(
            contractVersion: bundled.manifest.contractVersion,
            generation: generation,
            minimumAppVersion: minimumAppVersion,
            datasets: bundled.manifest.datasets
        ),
        payloads: bundled.payloads
    )
}

private func releaseResponseData(
    _ manifest: OperationalReleaseManifest
) throws -> Data {
    let encodedDatasets = try JSONEncoder().encode(manifest.datasets)
    let datasets = try JSONSerialization.jsonObject(with: encodedDatasets)
    return try JSONSerialization.data(
        withJSONObject: [[
            "contract_version": manifest.contractVersion,
            "generation": manifest.generation,
            "minimum_app_version": manifest.minimumAppVersion,
            "datasets": datasets
        ]]
    )
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
