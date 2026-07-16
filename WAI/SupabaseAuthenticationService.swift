import Auth
import Foundation

protocol WAISupabaseAuthSessionBackend {
    func restoreSession(
        _ persistedSession: WAIAuthSession
    ) async throws -> WAIAuthSession
    func currentValidSession() async throws -> WAIAuthSession
    func signInWithApple(
        credential: WAIAppleSignInCredential
    ) async throws -> WAIAuthSession
    func signOut() async throws
    func discardSession() async throws
}

final class SupabaseWAIAuthenticationService: WAIAuthenticationServicing {
    private let authBackend: WAISupabaseAuthSessionBackend
    private let profileService: WAIProfileServing
    private let accountDeletionService: WAIAccountDeletionServing
    private let sessionStore: WAIAuthSessionStoring
    private let operationGate = WAIAuthenticationOperationGate()
    private let sessionStateLock = NSLock()
    private var sessionGeneration: UInt64 = 0

    init(
        authBackend: WAISupabaseAuthSessionBackend,
        profileService: WAIProfileServing,
        accountDeletionService: WAIAccountDeletionServing,
        sessionStore: WAIAuthSessionStoring = KeychainWAIAuthSessionStore()
    ) {
        self.authBackend = authBackend
        self.profileService = profileService
        self.accountDeletionService = accountDeletionService
        self.sessionStore = sessionStore
    }

    convenience init(configuration: WAIBackendConfiguration) {
        let profileService = SupabaseWAIBackendClient(
            configuration: configuration
        )
        self.init(
            authBackend: SupabaseAuthSessionBackend(
                configuration: configuration
            ),
            profileService: profileService,
            accountDeletionService: SupabaseWAIAccountDeletionClient(
                configuration: configuration
            )
        )
    }

    func restoreSession() async throws -> WAIAuthSession? {
        let generation = currentSessionGeneration()
        return try await operationGate.run {
            guard let persistedSession = try self.loadPersistedSession() else {
                return nil
            }

            do {
                let session = try await self.authBackend.restoreSession(
                    persistedSession
                )
                guard session.userID == persistedSession.userID else {
                    try self.invalidateAndClearPersistedSession(
                        ifCurrent: generation
                    )
                    throw WAIAuthenticationServiceError.invalidResponse
                }
                try self.savePersistedSession(
                    session,
                    generation: generation
                )
                return session
            } catch {
                throw self.mapAuthError(error)
            }
        }
    }

    func validSession() async throws -> WAIAuthSession {
        let generation = currentSessionGeneration()
        return try await operationGate.run {
            try await self.validSession(generation: generation)
        }
    }

    private func validSession(
        generation: UInt64
    ) async throws -> WAIAuthSession {
        do {
            let session = try await authBackend.currentValidSession()
            try savePersistedSession(session, generation: generation)
            return session
        } catch WAIAuthenticationServiceError.sessionUnavailable {
            guard let persistedSession = try loadPersistedSession() else {
                throw WAIAuthenticationServiceError.sessionUnavailable
            }

            do {
                let session = try await authBackend.restoreSession(persistedSession)
                guard session.userID == persistedSession.userID else {
                    try invalidateAndClearPersistedSession(
                        ifCurrent: generation
                    )
                    throw WAIAuthenticationServiceError.invalidResponse
                }
                try savePersistedSession(session, generation: generation)
                return session
            } catch {
                throw mapAuthError(error)
            }
        } catch {
            throw mapAuthError(error)
        }
    }

    func signInWithApple(
        credential: WAIAppleSignInCredential
    ) async throws -> WAIAuthSession {
        guard credential.isValid else {
            throw WAIAuthenticationServiceError.authenticationFailed
        }
        let generation = currentSessionGeneration()

        return try await operationGate.run {
            do {
                let session = try await self.authBackend.signInWithApple(
                    credential: credential
                )
                do {
                    try self.savePersistedSession(
                        session,
                        generation: generation
                    )
                } catch {
                    try? await self.authBackend.signOut()
                    throw error
                }
                return session
            } catch {
                throw self.mapAuthError(error)
            }
        }
    }

    func fetchProfile(for session: WAIAuthSession) async throws -> WAIUserProfile {
        let generation = currentSessionGeneration()
        return try await operationGate.run {
            let currentSession = try await self.validSession(
                generation: generation
            )
            guard currentSession.userID == session.userID else {
                try self.invalidateAndClearPersistedSession(
                    ifCurrent: generation
                )
                try? await self.authBackend.discardSession()
                throw WAIAuthenticationServiceError.invalidResponse
            }

            do {
                let profile = try await self.profileService.fetchProfile(
                    session: currentSession
                )
                guard self.isCurrentSessionGeneration(generation) else {
                    throw WAIAuthenticationServiceError.cancelled
                }
                return profile
            } catch {
                let mappedError = self.mapProfileError(error)
                if mappedError == .invalidResponse {
                    try self.invalidateAndClearPersistedSession(
                        ifCurrent: generation
                    )
                    try? await self.authBackend.discardSession()
                }
                throw mappedError
            }
        }
    }

    func deleteAccount(
        credential: WAIAppleSignInCredential,
        expectedUserID: UUID
    ) async throws {
        guard credential.isValidForAccountDeletion,
              let authorizationCode = credential.authorizationCode else {
            throw WAIAuthenticationServiceError.authenticationFailed
        }
        let generation = currentSessionGeneration()

        try await operationGate.run {
            let currentSession: WAIAuthSession
            do {
                currentSession = try await self.validSession(
                    generation: generation
                )
            } catch {
                throw self.mapAuthError(error)
            }

            guard currentSession.userID == expectedUserID else {
                try self.invalidateAndClearPersistedSession(
                    ifCurrent: generation
                )
                do {
                    try await self.authBackend.discardSession()
                } catch {
                    throw WAIAuthenticationServiceError.secureStorage
                }
                throw WAIAuthenticationServiceError.invalidResponse
            }

            do {
                try await self.accountDeletionService.deleteAccount(
                    session: currentSession,
                    authorizationCode: authorizationCode
                )
            } catch {
                throw self.mapAuthError(error)
            }

            var cleanupFailed = false
            do {
                try self.invalidateAndClearPersistedSession()
            } catch {
                cleanupFailed = true
            }
            do {
                try await self.authBackend.discardSession()
            } catch {
                cleanupFailed = true
            }
            if cleanupFailed {
                throw WAIAuthenticationServiceError.secureStorage
            }
        }
    }

    func signOut(session: WAIAuthSession?) async throws {
        var secureStorageFailure = false
        do {
            try invalidateAndClearPersistedSession()
        } catch {
            secureStorageFailure = true
        }

        var remoteError: WAIAuthenticationServiceError?

        do {
            try await operationGate.run {
                if let session {
                    do {
                        _ = try await self.authBackend.currentValidSession()
                    } catch WAIAuthenticationServiceError.sessionUnavailable {
                        _ = try await self.authBackend.restoreSession(session)
                    }
                }
                try await self.authBackend.signOut()
            }
        } catch {
            remoteError = mapAuthError(error)
        }

        if secureStorageFailure {
            throw WAIAuthenticationServiceError.secureStorage
        }

        if let remoteError {
            throw remoteError
        }
    }

    private func loadPersistedSession() throws -> WAIAuthSession? {
        sessionStateLock.lock()
        defer { sessionStateLock.unlock() }
        do {
            return try sessionStore.load()
        } catch {
            throw WAIAuthenticationServiceError.secureStorage
        }
    }

    private func savePersistedSession(
        _ session: WAIAuthSession,
        generation: UInt64
    ) throws {
        guard session.isValid else {
            throw WAIAuthenticationServiceError.invalidResponse
        }

        sessionStateLock.lock()
        defer { sessionStateLock.unlock() }
        guard generation == sessionGeneration else {
            throw WAIAuthenticationServiceError.cancelled
        }
        do {
            try sessionStore.save(session)
        } catch {
            throw WAIAuthenticationServiceError.secureStorage
        }
    }

    private func currentSessionGeneration() -> UInt64 {
        sessionStateLock.lock()
        defer { sessionStateLock.unlock() }
        return sessionGeneration
    }

    private func isCurrentSessionGeneration(_ generation: UInt64) -> Bool {
        sessionStateLock.lock()
        defer { sessionStateLock.unlock() }
        return generation == sessionGeneration
    }

    private func invalidateAndClearPersistedSession(
        ifCurrent expectedGeneration: UInt64? = nil
    ) throws {
        sessionStateLock.lock()
        defer { sessionStateLock.unlock() }

        if let expectedGeneration,
           expectedGeneration != sessionGeneration {
            throw WAIAuthenticationServiceError.cancelled
        }

        sessionGeneration &+= 1
        do {
            try sessionStore.clear()
        } catch {
            throw WAIAuthenticationServiceError.secureStorage
        }
    }

    private func mapAuthError(_ error: Error) -> WAIAuthenticationServiceError {
        if let error = error as? WAIAuthenticationServiceError {
            return error
        }
        if error is URLError {
            return .networkUnavailable
        }
        if error is DecodingError {
            return .invalidResponse
        }
        return .serviceUnavailable
    }

    private func mapProfileError(_ error: Error) -> WAIAuthenticationServiceError {
        guard let error = error as? WAIPrivateBackendError else {
            return mapAuthError(error)
        }

        switch error {
        case .networkUnavailable:
            return .networkUnavailable
        case .unauthorized:
            return .sessionUnavailable
        case .serviceUnavailable:
            return .serviceUnavailable
        case .forbidden, .notFound, .invalidResponse, .responseTooLarge:
            return .invalidResponse
        }
    }
}

private actor WAIAuthenticationOperationGate {
    private var isRunning = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        guard isRunning else {
            isRunning = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        guard !waiters.isEmpty else {
            isRunning = false
            return
        }

        waiters.removeFirst().resume()
    }
}

final class SupabaseAuthSessionBackend: WAISupabaseAuthSessionBackend {
    private enum Operation {
        case restore
        case signIn
        case session
        case signOut
    }

    private let client: AuthClient

    init(
        configuration: WAIBackendConfiguration,
        fetch: @escaping AuthClient.FetchHandler = {
            try await WAIPrivateNetworkSession.boundedData(
                for: $0,
                maximumBytes: 262_144
            )
        }
    ) {
        let authURL = configuration.baseURL
            .appendingPathComponent("auth")
            .appendingPathComponent("v1")
        client = AuthClient(
            url: authURL,
            headers: [
                "Authorization": "Bearer \(configuration.publishableKey)",
                "apikey": configuration.publishableKey
            ],
            flowType: .pkce,
            storageKey: "wai-auth-transient-v1",
            localStorage: WAITransientAuthLocalStorage(),
            fetch: fetch,
            autoRefreshToken: false,
            emitLocalSessionAsInitialSession: false
        )
    }

    func restoreSession(
        _ persistedSession: WAIAuthSession
    ) async throws -> WAIAuthSession {
        do {
            let session = try await client.setSession(
                accessToken: persistedSession.accessToken,
                refreshToken: persistedSession.refreshToken
            )
            return try Self.map(session)
        } catch {
            throw Self.map(error, operation: .restore)
        }
    }

    func currentValidSession() async throws -> WAIAuthSession {
        do {
            return try Self.map(try await client.session)
        } catch {
            throw Self.map(error, operation: .session)
        }
    }

    func signInWithApple(
        credential: WAIAppleSignInCredential
    ) async throws -> WAIAuthSession {
        guard credential.isValid else {
            throw WAIAuthenticationServiceError.authenticationFailed
        }

        do {
            let session = try await client.signInWithIdToken(
                credentials: OpenIDConnectCredentials(
                    provider: .apple,
                    idToken: credential.identityToken,
                    nonce: credential.rawNonce
                )
            )
            return try Self.map(session)
        } catch {
            throw Self.map(error, operation: .signIn)
        }
    }

    func signOut() async throws {
        do {
            try await client.signOut(scope: .global)
        } catch {
            throw Self.map(error, operation: .signOut)
        }
    }

    func discardSession() async throws {
        do {
            try await client.signOut(scope: .local)
        } catch {
            throw Self.map(error, operation: .signOut)
        }
    }

    private static func map(_ session: Session) throws -> WAIAuthSession {
        let expiresAt = Date(timeIntervalSince1970: session.expiresAt)
        let mapped = WAIAuthSession(
            userID: session.user.id,
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            expiresAt: expiresAt
        )
        guard mapped.isValid,
              session.expiresAt.isFinite,
              session.expiresAt > 0 else {
            throw WAIAuthenticationServiceError.invalidResponse
        }
        return mapped
    }

    private static func map(
        _ error: Error,
        operation: Operation
    ) -> WAIAuthenticationServiceError {
        if let error = error as? WAIAuthenticationServiceError {
            return error
        }
        if error is CancellationError {
            return .cancelled
        }
        if error is URLError {
            return .networkUnavailable
        }
        if error is DecodingError {
            return .invalidResponse
        }
        guard let error = error as? AuthError else {
            return .serviceUnavailable
        }

        let sessionErrors: Set<ErrorCode> = [
            .sessionNotFound,
            .sessionExpired,
            .refreshTokenNotFound,
            .refreshTokenAlreadyUsed,
            .invalidJWT,
            .userNotFound,
            .userBanned
        ]
        if sessionErrors.contains(error.errorCode) {
            return .sessionUnavailable
        }

        if case let .api(_, _, _, response) = error {
            if response.statusCode == 429 || response.statusCode >= 500 {
                return .serviceUnavailable
            }
            if operation == .signIn, (400..<500).contains(response.statusCode) {
                return .authenticationFailed
            }
            if response.statusCode == 401 {
                return .sessionUnavailable
            }
            return .invalidResponse
        }

        switch operation {
        case .signIn:
            return .authenticationFailed
        case .restore, .session:
            return .sessionUnavailable
        case .signOut:
            return .serviceUnavailable
        }
    }
}

private final class WAITransientAuthLocalStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func store(key: String, value: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }

    func retrieve(key: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func remove(key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: key)
    }
}
