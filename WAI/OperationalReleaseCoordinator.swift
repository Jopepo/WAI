import Foundation

struct OperationalReleasePackage: Equatable, Sendable {
    let manifest: OperationalReleaseManifest
    let payloads: [OperationalDatasetKey: Data]
}

enum OperationalReleaseOrigin: Equatable, Sendable {
    case bundled
    case secureCache
    case remote
}

struct OperationalReleaseSelection: Equatable, Sendable {
    let package: OperationalReleasePackage
    let origin: OperationalReleaseOrigin
}

enum BundledOperationalReleaseError: Error, Equatable {
    case missingResource(String)
    case missingSource(OperationalDatasetKey)
}

enum OperationalReleaseCoordinatorError: Error, Equatable {
    case noValidatedLocalRelease
    case secureStorage
    case operationInvalidated
}

protocol BundledOperationalReleaseProviding {
    func load() throws -> OperationalReleasePackage
}

protocol OperationalReleaseCoordinating {
    func loadBestAvailable(
        for userID: UUID
    ) async throws -> OperationalReleaseSelection
    func refresh(
        for session: WAIAuthSession,
        refreshToken: OperationalReleaseRefreshToken
    ) async throws -> OperationalReleaseSelection
}

struct BundledOperationalReleaseProvider: BundledOperationalReleaseProviding {
    private let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    func load() throws -> OperationalReleasePackage {
        let hotel = try data(named: "wai_hotel_map_rev52")
        let transport = try data(named: "wai_transport_rules_rev74")
        let whatsNew = try data(named: "wai_whats_new_current")

        let decoder = JSONDecoder()
        let hotelDocument = try decoder.decode(HotelDocument.self, from: hotel)
        let transportDocument = try decoder.decode(StationData.self, from: transport)
        let whatsNewDocument = try decoder.decode(WhatsNewDocument.self, from: whatsNew)

        guard let hotelSource = hotelDocument.sourceInfo else {
            throw BundledOperationalReleaseError.missingSource(.hotelMap)
        }
        guard let transportSource = transportDocument.sourceInfo else {
            throw BundledOperationalReleaseError.missingSource(.transportRules)
        }
        guard let whatsNewSource = whatsNewDocument.sourceInfo else {
            throw BundledOperationalReleaseError.missingSource(.whatsNew)
        }

        let payloads: [OperationalDatasetKey: Data] = [
            .hotelMap: hotel,
            .transportRules: transport,
            .whatsNew: whatsNew
        ]
        let manifest = OperationalReleaseManifest(
            contractVersion: OperationalReleaseValidator.currentContractVersion,
            generation: 1,
            minimumAppVersion: "3.0",
            datasets: [
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
        )
        try OperationalReleaseValidator.validatePackage(
            manifest: manifest,
            payloads: payloads
        )
        return OperationalReleasePackage(manifest: manifest, payloads: payloads)
    }

    private func data(named resource: String) throws -> Data {
        guard let url = bundle.url(forResource: resource, withExtension: "json") else {
            throw BundledOperationalReleaseError.missingResource(resource)
        }
        return try Data(contentsOf: url)
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
}

actor OperationalReleaseCoordinator: OperationalReleaseCoordinating {
    private let remote: WAIPrivateOperationalDataServing
    private let cache: ProtectedOperationalReleaseCache
    private let bundled: BundledOperationalReleaseProviding?
    private let currentAppVersion: String

    init(
        remote: WAIPrivateOperationalDataServing,
        cache: ProtectedOperationalReleaseCache,
        bundled: BundledOperationalReleaseProviding? = nil,
        currentAppVersion: String
    ) {
        self.remote = remote
        self.cache = cache
        self.bundled = bundled
        self.currentAppVersion = currentAppVersion
    }

    func loadBestAvailable(
        for userID: UUID
    ) async throws -> OperationalReleaseSelection {
        if let cached = try validatedCachedRelease(for: userID) {
            return OperationalReleaseSelection(
                package: OperationalReleasePackage(
                    manifest: cached.manifest,
                    payloads: cached.payloads
                ),
                origin: .secureCache
            )
        }

        guard let bundled else {
            throw OperationalReleaseCoordinatorError.noValidatedLocalRelease
        }
        return OperationalReleaseSelection(
            package: try bundled.load(),
            origin: .bundled
        )
    }

    func refresh(
        for session: WAIAuthSession,
        refreshToken: OperationalReleaseRefreshToken
    ) async throws -> OperationalReleaseSelection {
        guard session.isValid else {
            throw WAIAuthenticationServiceError.sessionUnavailable
        }

        try validateRefreshToken(refreshToken)
        let cached = try validatedCachedRelease(for: session.userID)
        let candidate = try await remote.fetchActiveRelease(session: session)
        try validateRefreshToken(refreshToken)
        try OperationalReleaseValidator.validateCompatibility(
            candidate,
            currentAppVersion: currentAppVersion
        )
        try OperationalReleaseValidator.validateCandidate(
            candidate,
            replacing: cached?.manifest
        )

        if let cached, cached.manifest == candidate {
            return OperationalReleaseSelection(
                package: OperationalReleasePackage(
                    manifest: cached.manifest,
                    payloads: cached.payloads
                ),
                origin: .secureCache
            )
        }

        var payloads: [OperationalDatasetKey: Data] = [:]
        for descriptor in candidate.datasets {
            payloads[descriptor.key] = try await remote.downloadDataset(
                descriptor,
                session: session
            )
            try validateRefreshToken(refreshToken)
        }
        try OperationalReleaseValidator.validatePackage(
            manifest: candidate,
            payloads: payloads
        )
        do {
            try cache.save(
                ownerUserID: session.userID,
                manifest: candidate,
                payloads: payloads,
                refreshToken: refreshToken
            )
        } catch ProtectedOperationalReleaseCacheError.operationInvalidated {
            throw OperationalReleaseCoordinatorError.operationInvalidated
        } catch {
            try? cache.discardInvalidContents()
            throw OperationalReleaseCoordinatorError.secureStorage
        }
        return OperationalReleaseSelection(
            package: OperationalReleasePackage(
                manifest: candidate,
                payloads: payloads
            ),
            origin: .remote
        )
    }

    private func validateRefreshToken(
        _ token: OperationalReleaseRefreshToken
    ) throws {
        do {
            try cache.validateRefreshToken(token)
        } catch ProtectedOperationalReleaseCacheError.operationInvalidated {
            throw OperationalReleaseCoordinatorError.operationInvalidated
        } catch {
            throw OperationalReleaseCoordinatorError.secureStorage
        }
    }

    private func validatedCachedRelease(
        for userID: UUID
    ) throws -> (
        manifest: OperationalReleaseManifest,
        payloads: [OperationalDatasetKey: Data]
    )? {
        do {
            guard let cached = try cache.load(for: userID) else {
                return nil
            }
            try OperationalReleaseValidator.validateCompatibility(
                cached.manifest,
                currentAppVersion: currentAppVersion
            )
            return cached
        } catch {
            do {
                try cache.discardInvalidContents()
            } catch {
                throw OperationalReleaseCoordinatorError.secureStorage
            }
            return nil
        }
    }
}
