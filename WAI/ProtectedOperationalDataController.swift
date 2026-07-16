import Foundation

enum OperationalDataServiceMode: Equatable, Sendable {
    case legacyRemote
    case protectedRelease
}

enum WAIProtectedDataSyncState: Equatable, Sendable {
    case current
    case offline
    case refreshDeferred
    case remoteRejected
}

struct WAIProtectedDataReadyState: Equatable, Sendable {
    let origin: OperationalReleaseOrigin
    let generation: Int
    let syncState: WAIProtectedDataSyncState
    let checkedAt: Date?
}

enum WAIProtectedDataFailure: Equatable, Sendable {
    case unavailable
    case authorization
    case secureStorage
}

enum WAIProtectedDataState: Equatable, Sendable {
    case idle
    case loading
    case ready(WAIProtectedDataReadyState)
    case failed(WAIProtectedDataFailure)
}

private struct OperationalReleaseDocuments {
    let stations: StationData
    let hotels: HotelDocument
    let whatsNew: WhatsNewDocument
}

@MainActor
final class WAIProtectedOperationalDataController: ObservableObject {
    @Published private(set) var state: WAIProtectedDataState = .idle

    let dataService: DataService
    let hotelDataService: HotelDataService
    let whatsNewDataService: WhatsNewDataService

    private let authenticationService: WAIAuthenticationServicing
    private let releaseCoordinator: OperationalReleaseCoordinating
    private let releaseAccessFence: OperationalReleaseAccessFence
    private let now: () -> Date
    private var operationID = UUID()
    private var ownerUserID: UUID?

    init(
        authenticationService: WAIAuthenticationServicing,
        releaseCoordinator: OperationalReleaseCoordinating,
        releaseAccessFence: OperationalReleaseAccessFence =
            OperationalReleaseAccessFence(),
        dataService: DataService? = nil,
        hotelDataService: HotelDataService? = nil,
        whatsNewDataService: WhatsNewDataService? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.authenticationService = authenticationService
        self.releaseCoordinator = releaseCoordinator
        self.releaseAccessFence = releaseAccessFence
        self.dataService = dataService ?? DataService(mode: .protectedRelease)
        self.hotelDataService = hotelDataService
            ?? HotelDataService(mode: .protectedRelease)
        self.whatsNewDataService = whatsNewDataService
            ?? WhatsNewDataService(mode: .protectedRelease)
        self.now = now
    }

    func prepare(for access: WAIApprovedAccess) async {
        let refreshToken = releaseAccessFence.makeToken()
        let operation = UUID()
        operationID = operation
        let canRetainReadyState: Bool
        if ownerUserID == access.userID,
           case .ready = state {
            canRetainReadyState = true
        } else {
            canRetainReadyState = false
            dataService.clearProtectedData()
            hotelDataService.clearProtectedData()
            whatsNewDataService.clearProtectedData()
        }
        ownerUserID = access.userID

        if !canRetainReadyState {
            state = .loading
        }

        let localSelection: OperationalReleaseSelection
        do {
            localSelection = try await releaseCoordinator.loadBestAvailable(
                for: access.userID
            )
            guard isCurrent(operation) else {
                return
            }
            try apply(localSelection)
        } catch {
            guard isCurrent(operation) else {
                return
            }
            if let failure = failClosedReason(for: error) {
                reset()
                state = .failed(failure)
                return
            }
            switch access.mode {
            case .offline:
                state = .failed(.unavailable)
            case .online:
                await refreshRemote(
                    for: access,
                    retaining: nil,
                    operation: operation,
                    refreshToken: refreshToken
                )
            }
            return
        }

        switch access.mode {
        case .offline:
            state = .ready(
                readyState(
                    for: localSelection,
                    syncState: .offline,
                    checkedAt: nil
                )
            )
        case .online:
            await refreshRemote(
                for: access,
                retaining: localSelection,
                operation: operation,
                refreshToken: refreshToken
            )
        }
    }

    func reset() {
        releaseAccessFence.invalidate()
        operationID = UUID()
        ownerUserID = nil
        dataService.clearProtectedData()
        hotelDataService.clearProtectedData()
        whatsNewDataService.clearProtectedData()
        state = .idle
    }

    private func refreshRemote(
        for access: WAIApprovedAccess,
        retaining localSelection: OperationalReleaseSelection?,
        operation: UUID,
        refreshToken: OperationalReleaseRefreshToken
    ) async {
        do {
            let session = try await authenticationService.validSession()
            guard session.userID == access.userID else {
                throw WAIAuthenticationServiceError.invalidResponse
            }
            guard isCurrent(operation) else {
                return
            }
            let refreshed = try await releaseCoordinator.refresh(
                for: session,
                refreshToken: refreshToken
            )
            guard isCurrent(operation) else {
                return
            }
            try apply(refreshed)
            state = .ready(
                readyState(
                    for: refreshed,
                    syncState: .current,
                    checkedAt: now()
                )
            )
        } catch {
            guard isCurrent(operation) else {
                return
            }

            if let failure = failClosedReason(for: error) {
                reset()
                state = .failed(failure)
                return
            }

            if let localSelection {
                let syncState: WAIProtectedDataSyncState =
                    isRejectedRemoteData(error)
                    ? .remoteRejected
                    : .refreshDeferred
                state = .ready(
                    readyState(
                        for: localSelection,
                        syncState: syncState,
                        checkedAt: now()
                    )
                )
            } else {
                state = .failed(.unavailable)
            }
        }
    }

    private func apply(_ selection: OperationalReleaseSelection) throws {
        let documents = try decode(selection.package)
        let kind = sourceKind(for: selection.origin)
        let loadedAt = selection.origin == .remote ? now() : nil
        let descriptors = Dictionary(
            uniqueKeysWithValues: selection.package.manifest.datasets.map {
                ($0.key, $0)
            }
        )

        guard let transport = descriptors[.transportRules],
              let hotel = descriptors[.hotelMap],
              let whatsNew = descriptors[.whatsNew] else {
            throw OperationalReleaseValidationError.incompleteDatasetSet
        }

        dataService.applyProtected(
            document: documents.stations,
            sourceInfo: sourceInfo(
                descriptor: transport,
                kind: kind,
                loadedAt: loadedAt
            )
        )
        hotelDataService.applyProtected(
            document: documents.hotels,
            sourceInfo: sourceInfo(
                descriptor: hotel,
                kind: kind,
                loadedAt: loadedAt
            )
        )
        whatsNewDataService.applyProtected(
            document: documents.whatsNew,
            sourceInfo: sourceInfo(
                descriptor: whatsNew,
                kind: kind,
                loadedAt: loadedAt
            )
        )
    }

    private func decode(
        _ package: OperationalReleasePackage
    ) throws -> OperationalReleaseDocuments {
        try OperationalReleaseValidator.validatePackage(
            manifest: package.manifest,
            payloads: package.payloads
        )
        guard let transportData = package.payloads[.transportRules],
              let hotelData = package.payloads[.hotelMap],
              let whatsNewData = package.payloads[.whatsNew] else {
            throw OperationalReleaseValidationError.payloadSetMismatch
        }

        let decoder = JSONDecoder()
        return OperationalReleaseDocuments(
            stations: try decoder.decode(StationData.self, from: transportData),
            hotels: try decoder.decode(HotelDocument.self, from: hotelData),
            whatsNew: try decoder.decode(WhatsNewDocument.self, from: whatsNewData)
        )
    }

    private func readyState(
        for selection: OperationalReleaseSelection,
        syncState: WAIProtectedDataSyncState,
        checkedAt: Date?
    ) -> WAIProtectedDataReadyState {
        WAIProtectedDataReadyState(
            origin: selection.origin,
            generation: selection.package.manifest.generation,
            syncState: syncState,
            checkedAt: checkedAt
        )
    }

    private func sourceInfo(
        descriptor: OperationalDatasetDescriptor,
        kind: OperationalDataSourceKind,
        loadedAt: Date?
    ) -> OperationalDataSourceInfo {
        OperationalDataSourceInfo(
            kind: kind,
            document: descriptor.source.document,
            revision: descriptor.source.revision,
            date: descriptor.source.date,
            loadedAt: loadedAt
        )
    }

    private func sourceKind(
        for origin: OperationalReleaseOrigin
    ) -> OperationalDataSourceKind {
        switch origin {
        case .bundled:
            return .bundled
        case .secureCache:
            return .cached
        case .remote:
            return .remote
        }
    }

    private func failClosedReason(
        for error: Error
    ) -> WAIProtectedDataFailure? {
        if let error = error as? OperationalReleaseCoordinatorError {
            switch error {
            case .secureStorage:
                return .secureStorage
            case .noValidatedLocalRelease, .operationInvalidated:
                return nil
            }
        }

        if let error = error as? WAIAuthenticationServiceError {
            switch error {
            case .secureStorage:
                return .secureStorage
            case .configuration, .authenticationFailed, .invalidResponse:
                return .authorization
            case .cancelled, .networkUnavailable, .sessionUnavailable,
                 .serviceUnavailable:
                return nil
            }
        }

        if let error = error as? WAIPrivateBackendError {
            switch error {
            case .unauthorized, .forbidden:
                return .authorization
            case .networkUnavailable, .notFound, .serviceUnavailable,
                 .invalidResponse, .responseTooLarge:
                return nil
            }
        }
        return nil
    }

    private func isRejectedRemoteData(_ error: Error) -> Bool {
        error is OperationalReleaseValidationError
        || error is DecodingError
        || (error as? WAIPrivateBackendError).map { backendError in
            switch backendError {
            case .notFound, .invalidResponse, .responseTooLarge:
                return true
            case .networkUnavailable, .unauthorized, .forbidden,
                 .serviceUnavailable:
                return false
            }
        } == true
    }

    private func isCurrent(_ operation: UUID) -> Bool {
        operationID == operation
    }
}
