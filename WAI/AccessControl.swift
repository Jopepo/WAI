import Foundation

enum WAIProfileAccessStatus: String, Codable, Equatable, Sendable {
    case pending
    case approved
    case revoked
}

struct WAIUserProfile: Codable, Equatable, Sendable {
    let id: UUID
    let approvalCode: String
    let accessStatus: WAIProfileAccessStatus
    let createdAt: Date
    let approvedAt: Date?
    let revokedAt: Date?

    var isValid: Bool {
        guard Self.isValidApprovalCode(approvalCode) else {
            return false
        }

        switch accessStatus {
        case .pending:
            return approvedAt == nil && revokedAt == nil
        case .approved:
            return approvedAt != nil && revokedAt == nil
        case .revoked:
            return revokedAt != nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case approvalCode = "approval_code"
        case accessStatus = "access_status"
        case createdAt = "created_at"
        case approvedAt = "approved_at"
        case revokedAt = "revoked_at"
    }

    private static func isValidApprovalCode(_ value: String) -> Bool {
        let bytes = value.utf8
        return bytes.count == 12 && bytes.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
        }
    }
}

struct WAIAuthSession: Codable, Equatable, Sendable, CustomDebugStringConvertible {
    static let maximumTokenBytes = 16_384

    let userID: UUID
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date

    var isValid: Bool {
        Self.isValidToken(accessToken)
        && Self.isValidToken(refreshToken)
        && expiresAt.timeIntervalSince1970.isFinite
        && expiresAt.timeIntervalSince1970 > 0
    }

    var debugDescription: String {
        "WAIAuthSession(userID: \(userID), expiresAt: \(expiresAt))"
    }

    private static func isValidToken(_ value: String) -> Bool {
        value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        && (1...maximumTokenBytes).contains(value.utf8.count)
    }
}

struct WAIAppleSignInCredential: Equatable, Sendable {
    static let maximumIdentityTokenBytes = 16_384
    static let maximumNonceBytes = 256

    let identityToken: String
    let rawNonce: String
    let authorizationCode: String?

    init(
        identityToken: String,
        rawNonce: String,
        authorizationCode: String? = nil
    ) {
        self.identityToken = identityToken
        self.rawNonce = rawNonce
        self.authorizationCode = authorizationCode
    }

    var isValid: Bool {
        identityToken == identityToken.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        && (1...Self.maximumIdentityTokenBytes).contains(
            identityToken.utf8.count
        )
        && rawNonce == rawNonce.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        && (1...Self.maximumNonceBytes).contains(rawNonce.utf8.count)
    }

    var isValidForAccountDeletion: Bool {
        guard isValid, let authorizationCode else {
            return false
        }
        let trimmed = authorizationCode.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmed == authorizationCode
        && (1...8_192).contains(authorizationCode.utf8.count)
    }
}

struct WAIOfflineApprovalGrant: Codable, Equatable, Sendable {
    let userID: UUID
    let approvedAt: Date
    let lastVerifiedAt: Date

    var isValid: Bool {
        approvedAt.timeIntervalSinceReferenceDate.isFinite
        && lastVerifiedAt.timeIntervalSinceReferenceDate.isFinite
        && lastVerifiedAt >= approvedAt
    }
}

enum WAIOfflineAccessPolicy {
    static let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    static func permits(
        _ grant: WAIOfflineApprovalGrant,
        at date: Date
    ) -> Bool {
        guard grant.isValid,
              date >= grant.lastVerifiedAt else {
            return false
        }
        return date.timeIntervalSince(grant.lastVerifiedAt) <= maximumAge
    }
}

enum WAIOfflineAccessReason: Equatable, Sendable {
    case networkUnavailable
    case sessionUnavailable
    case serviceUnavailable
}

enum WAIAccessMode: Equatable, Sendable {
    case online
    case offline(WAIOfflineAccessReason)
}

struct WAIApprovedAccess: Equatable, Sendable {
    let userID: UUID
    let mode: WAIAccessMode
    let lastVerifiedAt: Date
}

struct WAIPendingAccess: Equatable, Sendable {
    let userID: UUID
    let approvalCode: String
}

enum WAIAccessFailure: Equatable, Sendable {
    case configuration
    case authentication
    case invalidServerResponse
    case secureStorage
    case serviceUnavailable
}

enum WAIAccessState: Equatable, Sendable {
    case restoring
    case signedOut
    case signingIn
    case checkingApproval
    case signingOut
    case pending(WAIPendingAccess)
    case approved(WAIApprovedAccess)
    case revoked
    case failed(WAIAccessFailure)
}

enum WAIAccountDeletionFailure: Equatable, Sendable {
    case authentication
    case connection
    case serviceUnavailable
    case invalidServerResponse
    case secureStorage
}

enum WAIAccountDeletionResult: Equatable, Sendable {
    case deleted
    case failed(WAIAccountDeletionFailure)
}

enum WAIAuthenticationServiceError: Error, Equatable {
    case cancelled
    case authenticationFailed
    case networkUnavailable
    case sessionUnavailable
    case serviceUnavailable
    case invalidResponse
    case configuration
    case secureStorage

    var offlineReason: WAIOfflineAccessReason? {
        switch self {
        case .networkUnavailable:
            return .networkUnavailable
        case .sessionUnavailable:
            return .sessionUnavailable
        case .serviceUnavailable:
            return .serviceUnavailable
        case .cancelled, .authenticationFailed, .invalidResponse,
             .configuration, .secureStorage:
            return nil
        }
    }
}

protocol WAIAuthenticationServicing {
    func restoreSession() async throws -> WAIAuthSession?
    func validSession() async throws -> WAIAuthSession
    func signInWithApple(
        credential: WAIAppleSignInCredential
    ) async throws -> WAIAuthSession
    func fetchProfile(for session: WAIAuthSession) async throws -> WAIUserProfile
    func deleteAccount(
        credential: WAIAppleSignInCredential,
        expectedUserID: UUID
    ) async throws
    func signOut(session: WAIAuthSession?) async throws
}

protocol WAIAuthSessionStoring {
    func load() throws -> WAIAuthSession?
    func save(_ session: WAIAuthSession) throws
    func clear() throws
}

protocol WAIOfflineApprovalStoring {
    func load() throws -> WAIOfflineApprovalGrant?
    func save(_ grant: WAIOfflineApprovalGrant) throws
    func clear() throws
}

struct WAIAccountDeletionIntent: Codable, Equatable, Sendable {
    let userID: UUID
    let startedAt: Date
}

protocol WAIAccountDeletionIntentStoring {
    func load() throws -> WAIAccountDeletionIntent?
    func save(_ intent: WAIAccountDeletionIntent) throws
    func clear() throws
}

struct WAILocalSignOutIntent: Codable, Equatable, Sendable {
    let userID: UUID
    let startedAt: Date
}

protocol WAILocalSignOutIntentStoring {
    func load() throws -> WAILocalSignOutIntent?
    func save(_ intent: WAILocalSignOutIntent) throws
    func clear() throws
}

protocol WAISensitiveOperationalDataClearing {
    func clear() throws
}

@MainActor
final class WAIAccessController: ObservableObject {
    @Published private(set) var state: WAIAccessState = .restoring
    @Published private(set) var isDeletingAccount = false

    private let authenticationService: WAIAuthenticationServicing
    private let approvalStore: WAIOfflineApprovalStoring
    private let deletionIntentStore: WAIAccountDeletionIntentStoring
    private let signOutIntentStore: WAILocalSignOutIntentStoring
    private let sensitiveDataStore: WAISensitiveOperationalDataClearing
    private let now: () -> Date

    private var session: WAIAuthSession?
    private var operationID = UUID()

    init(
        authenticationService: WAIAuthenticationServicing,
        approvalStore: WAIOfflineApprovalStoring,
        deletionIntentStore: WAIAccountDeletionIntentStoring =
            KeychainWAIAccountDeletionIntentStore(),
        signOutIntentStore: WAILocalSignOutIntentStoring =
            KeychainWAILocalSignOutIntentStore(),
        sensitiveDataStore: WAISensitiveOperationalDataClearing,
        now: @escaping () -> Date = Date.init
    ) {
        self.authenticationService = authenticationService
        self.approvalStore = approvalStore
        self.deletionIntentStore = deletionIntentStore
        self.signOutIntentStore = signOutIntentStore
        self.sensitiveDataStore = sensitiveDataStore
        self.now = now
    }

    func restoreAccess() async {
        if await recoverInterruptedAccountDeletion() {
            return
        }
        if await recoverInterruptedSignOut() {
            return
        }

        let operation = beginOperation(state: .restoring)
        let restoredSession: WAIAuthSession?

        do {
            restoredSession = try await authenticationService.restoreSession()
        } catch {
            guard isCurrent(operation) else {
                return
            }
            handleServiceFailure(error, session: nil, operation: operation)
            return
        }

        guard isCurrent(operation) else {
            return
        }

        session = restoredSession
        guard let restoredSession else {
            do {
                try restoreOfflineGrantOrSignOut(
                    reason: .sessionUnavailable,
                    operation: operation
                )
            } catch {
                state = .failed(.secureStorage)
            }
            return
        }

        await resolveProfile(for: restoredSession, operation: operation)
    }

    func signIn(with credential: WAIAppleSignInCredential) async {
        guard credential.isValid else {
            state = .failed(.authentication)
            return
        }

        let previousState = state
        let operation = beginOperation(state: .signingIn)

        do {
            let newSession = try await authenticationService.signInWithApple(
                credential: credential
            )
            guard isCurrent(operation) else {
                return
            }
            guard newSession.isValid else {
                state = .failed(.invalidServerResponse)
                return
            }

            session = newSession
            state = .checkingApproval
            await resolveProfile(for: newSession, operation: operation)
        } catch WAIAuthenticationServiceError.cancelled {
            guard isCurrent(operation) else {
                return
            }
            state = previousState
        } catch {
            guard isCurrent(operation) else {
                return
            }
            handleServiceFailure(error, session: session, operation: operation)
        }
    }

    func refreshAccess() async {
        guard !isDeletingAccount else {
            return
        }
        guard let session else {
            await restoreAccess()
            return
        }

        let operation = beginOperation(state: .checkingApproval)
        await resolveProfile(for: session, operation: operation)
    }

    func signOut() async {
        let sessionToEnd = session
        let userID = accountUserID ?? sessionToEnd?.userID
        var secureSignOutFailure = false
        if let userID {
            do {
                try signOutIntentStore.save(
                    WAILocalSignOutIntent(
                        userID: userID,
                        startedAt: now()
                    )
                )
            } catch {
                secureSignOutFailure = true
            }
        }

        let operation = beginOperation(state: .signingOut)
        session = nil

        do {
            try clearLocalAuthorizationAndData()
        } catch {
            secureSignOutFailure = true
        }

        do {
            try await authenticationService.signOut(session: sessionToEnd)
        } catch WAIAuthenticationServiceError.secureStorage {
            secureSignOutFailure = true
        } catch {
            // Local sign-out must still complete if the remote service is unavailable.
        }

        guard isCurrent(operation) else {
            return
        }

        guard !secureSignOutFailure else {
            state = .failed(.secureStorage)
            return
        }

        do {
            try signOutIntentStore.clear()
            try deletionIntentStore.clear()
            state = .signedOut
        } catch {
            state = .failed(.secureStorage)
        }
    }

    func handleAppleCredentialRevocation() async {
        await signOut()
    }

    func deleteAccount(
        with credential: WAIAppleSignInCredential
    ) async -> WAIAccountDeletionResult {
        guard !isDeletingAccount,
              credential.isValidForAccountDeletion,
              let expectedUserID = accountUserID else {
            return .failed(.authentication)
        }

        let previousState = state
        do {
            try deletionIntentStore.save(
                WAIAccountDeletionIntent(
                    userID: expectedUserID,
                    startedAt: now()
                )
            )
        } catch {
            state = .failed(.secureStorage)
            return .failed(.secureStorage)
        }

        let operation = UUID()
        operationID = operation
        isDeletingAccount = true
        defer {
            if isCurrent(operation) {
                isDeletingAccount = false
            }
        }

        do {
            try await authenticationService.deleteAccount(
                credential: credential,
                expectedUserID: expectedUserID
            )
            guard isCurrent(operation) else {
                return .failed(.serviceUnavailable)
            }

            session = nil
            do {
                try clearLocalAuthorizationAndData()
                try deletionIntentStore.clear()
                try signOutIntentStore.clear()
                state = .signedOut
                return .deleted
            } catch {
                state = .failed(.secureStorage)
                return .failed(.secureStorage)
            }
        } catch {
            guard isCurrent(operation) else {
                return .failed(.serviceUnavailable)
            }
            guard let serviceError = error as? WAIAuthenticationServiceError else {
                return finishRecoverableDeletionFailure(
                    previousState: previousState,
                    failure: .serviceUnavailable
                )
            }

            switch serviceError {
            case .cancelled, .authenticationFailed:
                return finishRecoverableDeletionFailure(
                    previousState: previousState,
                    failure: .authentication
                )
            case .networkUnavailable:
                return await finishUnconfirmedDeletion(
                    operation: operation,
                    stateFailure: .authentication,
                    resultFailure: .connection
                )
            case .serviceUnavailable:
                return await finishUnconfirmedDeletion(
                    operation: operation,
                    stateFailure: .authentication,
                    resultFailure: .serviceUnavailable
                )
            case .configuration:
                return await finishUnconfirmedDeletion(
                    operation: operation,
                    stateFailure: .configuration,
                    resultFailure: .serviceUnavailable
                )
            case .secureStorage:
                session = nil
                try? clearLocalAuthorizationAndData()
                state = .failed(.secureStorage)
                return .failed(.secureStorage)
            case .sessionUnavailable, .invalidResponse:
                return await finishUnconfirmedDeletion(
                    operation: operation,
                    stateFailure: serviceError == .invalidResponse
                        ? .invalidServerResponse
                        : .authentication,
                    resultFailure: serviceError == .invalidResponse
                        ? .invalidServerResponse
                        : .authentication
                )
            }
        }
    }

    private func recoverInterruptedAccountDeletion() async -> Bool {
        let intent: WAIAccountDeletionIntent?
        do {
            intent = try deletionIntentStore.load()
        } catch {
            state = .failed(.secureStorage)
            return true
        }
        guard intent != nil else {
            return false
        }

        let operation = beginOperation(state: .signingOut)
        session = nil
        var secureFailure = false

        do {
            try clearLocalAuthorizationAndData()
        } catch {
            secureFailure = true
        }

        do {
            try await authenticationService.signOut(session: nil)
        } catch WAIAuthenticationServiceError.secureStorage {
            secureFailure = true
        } catch {
            // The local session is still cleared when the remote service is offline.
        }
        guard isCurrent(operation) else {
            return true
        }

        guard !secureFailure else {
            state = .failed(.secureStorage)
            return true
        }

        do {
            try deletionIntentStore.clear()
            try signOutIntentStore.clear()
            state = .signedOut
        } catch {
            state = .failed(.secureStorage)
        }
        return true
    }

    private func recoverInterruptedSignOut() async -> Bool {
        let intent: WAILocalSignOutIntent?
        do {
            intent = try signOutIntentStore.load()
        } catch {
            state = .failed(.secureStorage)
            return true
        }
        guard intent != nil else {
            return false
        }

        let operation = beginOperation(state: .signingOut)
        session = nil
        var secureFailure = false

        do {
            try clearLocalAuthorizationAndData()
        } catch {
            secureFailure = true
        }

        do {
            try await authenticationService.signOut(session: nil)
        } catch WAIAuthenticationServiceError.secureStorage {
            secureFailure = true
        } catch {
            // Local teardown still completes when the remote service is offline.
        }
        guard isCurrent(operation) else {
            return true
        }

        guard !secureFailure else {
            state = .failed(.secureStorage)
            return true
        }

        do {
            try signOutIntentStore.clear()
            state = .signedOut
        } catch {
            state = .failed(.secureStorage)
        }
        return true
    }

    private func finishRecoverableDeletionFailure(
        previousState: WAIAccessState,
        failure: WAIAccountDeletionFailure
    ) -> WAIAccountDeletionResult {
        do {
            try deletionIntentStore.clear()
            state = previousState
            return .failed(failure)
        } catch {
            session = nil
            try? clearLocalAuthorizationAndData()
            state = .failed(.secureStorage)
            return .failed(.secureStorage)
        }
    }

    private func finishUnconfirmedDeletion(
        operation: UUID,
        stateFailure: WAIAccessFailure,
        resultFailure: WAIAccountDeletionFailure
    ) async -> WAIAccountDeletionResult {
        session = nil
        var secureFailure = false

        do {
            try clearLocalAuthorizationAndData()
        } catch {
            secureFailure = true
        }

        do {
            try await authenticationService.signOut(session: nil)
        } catch WAIAuthenticationServiceError.secureStorage {
            secureFailure = true
        } catch {
            // Local session clearing still completes after a remote sign-out error.
        }

        guard isCurrent(operation) else {
            return .failed(.serviceUnavailable)
        }

        guard !secureFailure else {
            state = .failed(.secureStorage)
            return .failed(.secureStorage)
        }

        state = .failed(stateFailure)
        return .failed(resultFailure)
    }

    private func resolveProfile(
        for session: WAIAuthSession,
        operation: UUID
    ) async {
        let existingGrant: WAIOfflineApprovalGrant?
        do {
            existingGrant = try approvalStore.load()
            if let existingGrant, existingGrant.userID != session.userID {
                try clearLocalAuthorizationAndData()
            }
        } catch {
            guard isCurrent(operation) else {
                return
            }
            state = .failed(.secureStorage)
            return
        }

        let profile: WAIUserProfile
        do {
            profile = try await authenticationService.fetchProfile(for: session)
        } catch {
            guard isCurrent(operation) else {
                return
            }
            handleServiceFailure(error, session: session, operation: operation)
            return
        }

        guard isCurrent(operation) else {
            return
        }

        do {
            guard profile.id == session.userID, profile.isValid else {
                try clearLocalAuthorizationAndData()
                state = .failed(.invalidServerResponse)
                return
            }

            switch profile.accessStatus {
            case .pending:
                try clearLocalAuthorizationAndData()
                state = .pending(
                    WAIPendingAccess(
                        userID: profile.id,
                        approvalCode: profile.approvalCode
                    )
                )
            case .approved:
                guard let approvedAt = profile.approvedAt else {
                    try clearLocalAuthorizationAndData()
                    state = .failed(.invalidServerResponse)
                    return
                }

                let verifiedAt = now()
                let grant = WAIOfflineApprovalGrant(
                    userID: profile.id,
                    approvedAt: approvedAt,
                    lastVerifiedAt: verifiedAt
                )
                try approvalStore.save(grant)
                state = .approved(
                    WAIApprovedAccess(
                        userID: profile.id,
                        mode: .online,
                        lastVerifiedAt: verifiedAt
                    )
                )
            case .revoked:
                try clearLocalAuthorizationAndData()
                state = .revoked
            }
        } catch {
            state = .failed(.secureStorage)
        }
    }

    private var accountUserID: UUID? {
        switch state {
        case .approved(let access):
            return access.userID
        case .pending(let pending):
            return pending.userID
        case .revoked:
            return session?.userID
        case .restoring, .signedOut, .signingIn, .checkingApproval,
             .signingOut, .failed:
            return nil
        }
    }

    private func handleServiceFailure(
        _ error: Error,
        session: WAIAuthSession?,
        operation: UUID
    ) {
        guard isCurrent(operation) else {
            return
        }

        guard let serviceError = error as? WAIAuthenticationServiceError else {
            state = .failed(.serviceUnavailable)
            return
        }

        if serviceError == .invalidResponse {
            do {
                try clearLocalAuthorizationAndData()
                state = .failed(.invalidServerResponse)
            } catch {
                state = .failed(.secureStorage)
            }
            return
        }

        if let offlineReason = serviceError.offlineReason {
            do {
                let grant = try approvalStore.load()
                if let grant,
                   session == nil || grant.userID == session?.userID {
                    guard WAIOfflineAccessPolicy.permits(grant, at: now()) else {
                        try clearLocalAuthorizationAndData()
                        state = .failed(.authentication)
                        return
                    }
                    state = .approved(
                        WAIApprovedAccess(
                            userID: grant.userID,
                            mode: .offline(offlineReason),
                            lastVerifiedAt: grant.lastVerifiedAt
                        )
                    )
                    return
                }
            } catch {
                state = .failed(.secureStorage)
                return
            }
        }

        state = .failed(failure(for: serviceError))
    }

    private func restoreOfflineGrantOrSignOut(
        reason: WAIOfflineAccessReason,
        operation: UUID
    ) throws {
        guard isCurrent(operation) else {
            return
        }

        guard let grant = try approvalStore.load() else {
            state = .signedOut
            return
        }
        guard WAIOfflineAccessPolicy.permits(grant, at: now()) else {
            try clearLocalAuthorizationAndData()
            state = .failed(.authentication)
            return
        }

        state = .approved(
            WAIApprovedAccess(
                userID: grant.userID,
                mode: .offline(reason),
                lastVerifiedAt: grant.lastVerifiedAt
            )
        )
    }

    private func clearLocalAuthorizationAndData() throws {
        var firstError: Error?

        do {
            try approvalStore.clear()
        } catch {
            firstError = error
        }

        do {
            try sensitiveDataStore.clear()
        } catch {
            if firstError == nil {
                firstError = error
            }
        }

        if let firstError {
            throw firstError
        }
    }

    private func failure(
        for error: WAIAuthenticationServiceError
    ) -> WAIAccessFailure {
        switch error {
        case .configuration:
            return .configuration
        case .invalidResponse:
            return .invalidServerResponse
        case .secureStorage:
            return .secureStorage
        case .networkUnavailable, .serviceUnavailable:
            return .serviceUnavailable
        case .cancelled, .authenticationFailed, .sessionUnavailable:
            return .authentication
        }
    }

    private func beginOperation(state: WAIAccessState) -> UUID {
        let identifier = UUID()
        operationID = identifier
        isDeletingAccount = false
        self.state = state
        return identifier
    }

    private func isCurrent(_ identifier: UUID) -> Bool {
        operationID == identifier
    }
}
