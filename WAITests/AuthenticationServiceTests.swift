import AuthenticationServices
import Foundation
import Testing
@testable import WAI

struct WAIAppleSignInTests {
    @Test func nonceUsesRequestedLengthAndSHA256() throws {
        let generator = WAIAppleSignInNonceGenerator { count in
            (0..<count).map { UInt8($0 % 190) }
        }

        let request = try generator.makeRequest(length: 32)

        #expect(request.rawNonce == "0123456789ABCDEFGHIJKLMNOPQRSTUV")
        #expect(request.hashedNonce == WAIAppleSignInNonceGenerator.sha256(request.rawNonce))
        #expect(request.hashedNonce.count == 64)
    }

    @Test func sha256MatchesKnownDigest() {
        #expect(
            WAIAppleSignInNonceGenerator.sha256("test")
            == "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
        )
    }

    @Test func nonceRejectsUnsafeLengths() {
        let generator = WAIAppleSignInNonceGenerator { _ in [0] }

        #expect(throws: WAIAppleSignInPreparationError.invalidLength) {
            try generator.makeRequest(length: 8)
        }
    }

    @Test func credentialRequiresTokenAndMatchingRawNonce() throws {
        let credential = try WAIAppleSignInCredentialFactory.make(
            identityToken: Data("apple.identity.token".utf8),
            authorizationCode: Data("single-use-code".utf8),
            rawNonce: "raw-nonce"
        )

        #expect(
            credential == WAIAppleSignInCredential(
                identityToken: "apple.identity.token",
                rawNonce: "raw-nonce",
                authorizationCode: "single-use-code"
            )
        )
        #expect(credential.isValidForAccountDeletion)
        #expect(throws: WAIAppleSignInPreparationError.missingIdentityToken) {
            try WAIAppleSignInCredentialFactory.make(
                identityToken: nil,
                rawNonce: "raw-nonce"
            )
        }
        #expect(throws: WAIAppleSignInPreparationError.missingNonce) {
            try WAIAppleSignInCredentialFactory.make(
                identityToken: Data("token".utf8),
                rawNonce: nil
            )
        }
        #expect(throws: WAIAppleSignInPreparationError.invalidAuthorizationCode) {
            try WAIAppleSignInCredentialFactory.make(
                identityToken: Data("token".utf8),
                authorizationCode: Data(),
                rawNonce: "raw-nonce"
            )
        }
    }

    @Test func credentialRejectsOversizedTokenAndNonce() {
        #expect(throws: WAIAppleSignInPreparationError.invalidIdentityToken) {
            try WAIAppleSignInCredentialFactory.make(
                identityToken: Data(
                    String(
                        repeating: "x",
                        count: WAIAppleSignInCredential
                            .maximumIdentityTokenBytes + 1
                    ).utf8
                ),
                rawNonce: "raw-nonce"
            )
        }
        #expect(throws: WAIAppleSignInPreparationError.missingNonce) {
            try WAIAppleSignInCredentialFactory.make(
                identityToken: Data("token".utf8),
                rawNonce: String(
                    repeating: "n",
                    count: WAIAppleSignInCredential.maximumNonceBytes + 1
                )
            )
        }
    }

    @Test func authSessionRejectsUnsafeTokensAndDates() {
        let userID = UUID()
        let validExpiry = Date(timeIntervalSince1970: 1_784_116_000)

        #expect(!WAIAuthSession(
            userID: userID,
            accessToken: " access-token",
            refreshToken: "refresh-token",
            expiresAt: validExpiry
        ).isValid)
        #expect(!WAIAuthSession(
            userID: userID,
            accessToken: String(
                repeating: "x",
                count: WAIAuthSession.maximumTokenBytes + 1
            ),
            refreshToken: "refresh-token",
            expiresAt: validExpiry
        ).isValid)
        #expect(!WAIAuthSession(
            userID: userID,
            accessToken: "access-token",
            refreshToken: "refresh-token",
            expiresAt: Date(timeIntervalSince1970: .infinity)
        ).isValid)
    }

    @Test func appleCancellationRemainsAUserCancellation() {
        let error = NSError(
            domain: ASAuthorizationError.errorDomain,
            code: ASAuthorizationError.Code.canceled.rawValue
        )

        #expect(WAIAppleAuthorizationErrorMapper.map(error) == .cancelled)
    }
}

struct SupabaseWAIAuthenticationServiceTests {
    private let userID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let otherUserID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let expiresAt = Date(timeIntervalSince1970: 1_784_116_000)

    @Test func restoreWithoutPersistedSessionDoesNotCallNetwork() async throws {
        let fixture = makeFixture()

        let session = try await fixture.service.restoreSession()

        #expect(session == nil)
        #expect(fixture.backend.restoreCount == 0)
    }

    @Test func restoreRefreshesAndPersistsRotatedTokens() async throws {
        let oldSession = makeSession(accessToken: "old-access", refreshToken: "old-refresh")
        let refreshed = makeSession(accessToken: "new-access", refreshToken: "new-refresh")
        let fixture = makeFixture(storedSession: oldSession)
        fixture.backend.restoredSession = refreshed

        let result = try await fixture.service.restoreSession()

        #expect(result == refreshed)
        #expect(fixture.store.session == refreshed)
        #expect(fixture.backend.restoredInput == oldSession)
    }

    @Test func restoredAccountMismatchClearsSessionAndFailsClosed() async {
        let fixture = makeFixture(storedSession: makeSession())
        fixture.backend.restoredSession = makeSession(userID: otherUserID)

        await #expect(throws: WAIAuthenticationServiceError.invalidResponse) {
            try await fixture.service.restoreSession()
        }
        #expect(fixture.store.session == nil)
    }

    @Test func appleSignInIsPersisted() async throws {
        let fixture = makeFixture()
        let signedIn = makeSession(accessToken: "signed-in")
        fixture.backend.signedInSession = signedIn
        let credential = WAIAppleSignInCredential(
            identityToken: "identity-token",
            rawNonce: "raw-nonce"
        )

        let result = try await fixture.service.signInWithApple(
            credential: credential
        )

        #expect(result == signedIn)
        #expect(fixture.store.session == signedIn)
        #expect(fixture.backend.signInCredential == credential)
    }

    @Test func failedSecureSaveEndsNewRemoteSession() async {
        let fixture = makeFixture()
        fixture.backend.signedInSession = makeSession()
        fixture.store.saveError = true

        await #expect(throws: WAIAuthenticationServiceError.secureStorage) {
            try await fixture.service.signInWithApple(
                credential: WAIAppleSignInCredential(
                    identityToken: "identity-token",
                    rawNonce: "raw-nonce"
                )
            )
        }
        #expect(fixture.backend.signOutCount == 1)
    }

    @Test func validSessionFallsBackToPersistedSessionAfterLaunch() async throws {
        let persisted = makeSession(accessToken: "persisted")
        let restored = makeSession(accessToken: "restored")
        let fixture = makeFixture(storedSession: persisted)
        fixture.backend.currentError = WAIAuthenticationServiceError.sessionUnavailable
        fixture.backend.restoredSession = restored

        let result = try await fixture.service.validSession()

        #expect(result == restored)
        #expect(fixture.store.session == restored)
    }

    @Test func profileRequestUsesFreshSession() async throws {
        let stale = makeSession(accessToken: "stale")
        let current = makeSession(accessToken: "fresh")
        let fixture = makeFixture(storedSession: stale)
        fixture.backend.currentSession = current
        fixture.profile.profile = makeProfile()

        let profile = try await fixture.service.fetchProfile(for: stale)

        #expect(profile == makeProfile())
        #expect(fixture.profile.requestedSession == current)
        #expect(fixture.store.session == current)
    }

    @Test func forbiddenProfileResponseClearsPersistedSession() async {
        let session = makeSession()
        let fixture = makeFixture(storedSession: session)
        fixture.backend.currentSession = session
        fixture.profile.error = WAIPrivateBackendError.forbidden

        await #expect(throws: WAIAuthenticationServiceError.invalidResponse) {
            try await fixture.service.fetchProfile(for: session)
        }
        #expect(fixture.store.session == nil)
    }

    @Test func networkFailurePreservesSessionForOfflineFallback() async {
        let session = makeSession()
        let fixture = makeFixture(storedSession: session)
        fixture.backend.currentSession = session
        fixture.profile.error = WAIPrivateBackendError.networkUnavailable

        await #expect(throws: WAIAuthenticationServiceError.networkUnavailable) {
            try await fixture.service.fetchProfile(for: session)
        }
        #expect(fixture.store.session == session)
    }

    @Test func signOutClearsLocalSessionWhenRemoteCallFails() async {
        let session = makeSession()
        let fixture = makeFixture(storedSession: session)
        fixture.backend.currentSession = session
        fixture.backend.signOutError = WAIAuthenticationServiceError.networkUnavailable

        await #expect(throws: WAIAuthenticationServiceError.networkUnavailable) {
            try await fixture.service.signOut(session: session)
        }
        #expect(fixture.store.session == nil)
    }

    @Test func signOutClearsLocalSessionBeforeStartingRemoteCall() async throws {
        let session = makeSession()
        let fixture = makeFixture(storedSession: session)
        fixture.backend.currentSession = session
        var sessionSeenByRemoteSignOut: WAIAuthSession?
        fixture.backend.onSignOut = {
            sessionSeenByRemoteSignOut = fixture.store.session
        }

        try await fixture.service.signOut(session: session)

        #expect(sessionSeenByRemoteSignOut == nil)
    }

    @Test func inFlightSignInCannotRepersistAfterSignOut() async throws {
        let fixture = makeFixture()
        fixture.backend.signedInSession = makeSession(accessToken: "late")
        fixture.backend.shouldSuspendSignIn = true
        let credential = WAIAppleSignInCredential(
            identityToken: "identity-token",
            rawNonce: "raw-nonce"
        )

        let signIn = Task {
            try await fixture.service.signInWithApple(credential: credential)
        }
        while fixture.backend.signInCount == 0 {
            await Task.yield()
        }

        let signOut = Task {
            try await fixture.service.signOut(session: nil)
        }
        while fixture.store.clearCount == 0 {
            await Task.yield()
        }

        #expect(fixture.store.session == nil)
        fixture.backend.resumeSignIn()

        await #expect(throws: WAIAuthenticationServiceError.cancelled) {
            _ = try await signIn.value
        }
        try await signOut.value
        #expect(fixture.store.session == nil)
        #expect(fixture.backend.currentSession == nil)
    }

    @Test func queuedNewSignInSurvivesOlderSignInCleanup() async throws {
        let fixture = makeFixture()
        let oldSession = makeSession(accessToken: "old-late")
        let newSession = makeSession(accessToken: "new-current")
        fixture.backend.signedInSession = oldSession
        fixture.backend.shouldSuspendSignIn = true
        let credential = WAIAppleSignInCredential(
            identityToken: "identity-token",
            rawNonce: "raw-nonce"
        )

        let oldSignIn = Task {
            try await fixture.service.signInWithApple(credential: credential)
        }
        while fixture.backend.signInCount == 0 {
            await Task.yield()
        }

        let signOut = Task {
            try await fixture.service.signOut(session: nil)
        }
        while fixture.store.clearCount == 0 {
            await Task.yield()
        }

        fixture.backend.signedInSession = newSession
        let newSignIn = Task {
            try await fixture.service.signInWithApple(credential: credential)
        }
        fixture.backend.resumeSignIn()

        await #expect(throws: WAIAuthenticationServiceError.cancelled) {
            _ = try await oldSignIn.value
        }
        try await signOut.value
        let result = try await newSignIn.value

        #expect(result == newSession)
        #expect(fixture.store.session == newSession)
        #expect(fixture.backend.currentSession == newSession)
    }

    @Test func staleProfileResponseCannotInvalidateQueuedNewSignIn() async throws {
        let oldSession = makeSession(accessToken: "old-profile")
        let newSession = makeSession(accessToken: "new-profile")
        let fixture = makeFixture(storedSession: oldSession)
        fixture.backend.currentSession = oldSession
        fixture.profile.error = WAIPrivateBackendError.forbidden
        fixture.profile.shouldSuspend = true

        let profileRequest = Task {
            try await fixture.service.fetchProfile(for: oldSession)
        }
        while fixture.profile.callCount == 0 {
            await Task.yield()
        }

        let signOut = Task {
            try await fixture.service.signOut(session: oldSession)
        }
        while fixture.store.clearCount == 0 {
            await Task.yield()
        }

        fixture.backend.signedInSession = newSession
        let newSignIn = Task {
            try await fixture.service.signInWithApple(
                credential: WAIAppleSignInCredential(
                    identityToken: "identity-token",
                    rawNonce: "raw-nonce"
                )
            )
        }
        fixture.profile.resume()

        await #expect(throws: WAIAuthenticationServiceError.cancelled) {
            _ = try await profileRequest.value
        }
        try await signOut.value
        let result = try await newSignIn.value

        #expect(result == newSession)
        #expect(fixture.store.session == newSession)
        #expect(fixture.backend.currentSession == newSession)
    }

    @Test func signOutReportsSecureClearFailure() async {
        let session = makeSession()
        let fixture = makeFixture(storedSession: session)
        fixture.backend.currentSession = session
        fixture.store.clearError = true

        await #expect(throws: WAIAuthenticationServiceError.secureStorage) {
            try await fixture.service.signOut(session: session)
        }
    }

    @Test func accountDeletionUsesFreshSessionAndClearsLocalSession() async throws {
        let stored = makeSession(accessToken: "stored")
        let current = makeSession(accessToken: "fresh")
        let fixture = makeFixture(storedSession: stored)
        fixture.backend.currentSession = current
        let credential = deletionCredential()

        try await fixture.service.deleteAccount(
            credential: credential,
            expectedUserID: userID
        )

        #expect(fixture.deletion.session == current)
        #expect(fixture.deletion.authorizationCode == "single-use-code")
        #expect(fixture.store.session == nil)
        #expect(fixture.backend.discardCount == 1)
    }

    @Test func accountDeletionRequiresAuthorizationCode() async {
        let fixture = makeFixture(storedSession: makeSession())
        fixture.backend.currentSession = makeSession()

        await #expect(throws: WAIAuthenticationServiceError.authenticationFailed) {
            try await fixture.service.deleteAccount(
                credential: WAIAppleSignInCredential(
                    identityToken: "identity-token",
                    rawNonce: "raw-nonce"
                ),
                expectedUserID: userID
            )
        }
        #expect(fixture.deletion.callCount == 0)
        #expect(fixture.store.session != nil)
    }

    @Test func accountDeletionSessionMismatchFailsClosed() async {
        let fixture = makeFixture(storedSession: makeSession())
        fixture.backend.currentSession = makeSession(userID: otherUserID)

        await #expect(throws: WAIAuthenticationServiceError.invalidResponse) {
            try await fixture.service.deleteAccount(
                credential: deletionCredential(),
                expectedUserID: userID
            )
        }
        #expect(fixture.deletion.callCount == 0)
        #expect(fixture.store.session == nil)
        #expect(fixture.backend.discardCount == 1)
    }

    @Test func failedRemoteDeletionPreservesLocalSession() async {
        let session = makeSession()
        let fixture = makeFixture(storedSession: session)
        fixture.backend.currentSession = session
        fixture.deletion.error = WAIAuthenticationServiceError.networkUnavailable

        await #expect(throws: WAIAuthenticationServiceError.networkUnavailable) {
            try await fixture.service.deleteAccount(
                credential: deletionCredential(),
                expectedUserID: userID
            )
        }
        #expect(fixture.store.session == session)
        #expect(fixture.backend.discardCount == 0)
    }

    private func makeFixture(
        storedSession: WAIAuthSession? = nil
    ) -> AuthenticationServiceFixture {
        let backend = StubSupabaseAuthSessionBackend()
        let profile = StubProfileService()
        let deletion = StubAccountDeletionService()
        let store = InMemoryAuthSessionStore(session: storedSession)
        let service = SupabaseWAIAuthenticationService(
            authBackend: backend,
            profileService: profile,
            accountDeletionService: deletion,
            sessionStore: store
        )
        return AuthenticationServiceFixture(
            service: service,
            backend: backend,
            profile: profile,
            deletion: deletion,
            store: store
        )
    }

    private func makeSession(
        userID: UUID? = nil,
        accessToken: String = "access-token",
        refreshToken: String = "refresh-token"
    ) -> WAIAuthSession {
        WAIAuthSession(
            userID: userID ?? self.userID,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt
        )
    }

    private func makeProfile() -> WAIUserProfile {
        WAIUserProfile(
            id: userID,
            approvalCode: "A1B2C3D4E5F6",
            accessStatus: .approved,
            createdAt: expiresAt.addingTimeInterval(-7_200),
            approvedAt: expiresAt.addingTimeInterval(-3_600),
            revokedAt: nil
        )
    }

    private func deletionCredential() -> WAIAppleSignInCredential {
        WAIAppleSignInCredential(
            identityToken: "identity-token",
            rawNonce: "raw-nonce",
            authorizationCode: "single-use-code"
        )
    }
}

private struct AuthenticationServiceFixture {
    let service: SupabaseWAIAuthenticationService
    let backend: StubSupabaseAuthSessionBackend
    let profile: StubProfileService
    let deletion: StubAccountDeletionService
    let store: InMemoryAuthSessionStore
}

private final class StubSupabaseAuthSessionBackend: WAISupabaseAuthSessionBackend {
    var restoredSession: WAIAuthSession?
    var restoreError: Error?
    var currentSession: WAIAuthSession?
    var currentError: Error?
    var signedInSession: WAIAuthSession?
    var signInError: Error?
    var signOutError: Error?
    var shouldSuspendSignIn = false
    var onSignOut: (() -> Void)?
    private(set) var restoredInput: WAIAuthSession?
    private(set) var restoreCount = 0
    private(set) var signInCredential: WAIAppleSignInCredential?
    private(set) var signInCount = 0
    private(set) var signOutCount = 0
    private(set) var discardCount = 0
    private var signInContinuation: CheckedContinuation<Void, Never>?

    func restoreSession(
        _ persistedSession: WAIAuthSession
    ) async throws -> WAIAuthSession {
        restoreCount += 1
        restoredInput = persistedSession
        if let restoreError {
            throw restoreError
        }
        guard let restoredSession else {
            throw WAIAuthenticationServiceError.invalidResponse
        }
        currentSession = restoredSession
        return restoredSession
    }

    func currentValidSession() async throws -> WAIAuthSession {
        if let currentError {
            throw currentError
        }
        guard let currentSession else {
            throw WAIAuthenticationServiceError.sessionUnavailable
        }
        return currentSession
    }

    func signInWithApple(
        credential: WAIAppleSignInCredential
    ) async throws -> WAIAuthSession {
        signInCount += 1
        signInCredential = credential
        let shouldSuspend = shouldSuspendSignIn
        shouldSuspendSignIn = false
        guard let signedInSession else {
            throw WAIAuthenticationServiceError.invalidResponse
        }
        if shouldSuspend {
            await withCheckedContinuation { continuation in
                signInContinuation = continuation
            }
        }
        if let signInError {
            throw signInError
        }
        currentSession = signedInSession
        return signedInSession
    }

    func signOut() async throws {
        signOutCount += 1
        onSignOut?()
        currentSession = nil
        if let signOutError {
            throw signOutError
        }
    }

    func discardSession() async throws {
        discardCount += 1
        currentSession = nil
    }

    func resumeSignIn() {
        signInContinuation?.resume()
        signInContinuation = nil
    }
}

private final class StubProfileService: WAIProfileServing {
    var profile: WAIUserProfile?
    var error: Error?
    var shouldSuspend = false
    private(set) var requestedSession: WAIAuthSession?
    private(set) var callCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func fetchProfile(session: WAIAuthSession) async throws -> WAIUserProfile {
        callCount += 1
        requestedSession = session
        if shouldSuspend {
            shouldSuspend = false
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        if let error {
            throw error
        }
        guard let profile else {
            throw WAIPrivateBackendError.invalidResponse(nil)
        }
        return profile
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private final class StubAccountDeletionService: WAIAccountDeletionServing {
    var error: Error?
    private(set) var session: WAIAuthSession?
    private(set) var authorizationCode: String?
    private(set) var callCount = 0

    func deleteAccount(
        session: WAIAuthSession,
        authorizationCode: String
    ) async throws {
        callCount += 1
        self.session = session
        self.authorizationCode = authorizationCode
        if let error {
            throw error
        }
    }
}

private final class InMemoryAuthSessionStore: WAIAuthSessionStoring {
    var session: WAIAuthSession?
    var loadError = false
    var saveError = false
    var clearError = false
    private(set) var clearCount = 0

    init(session: WAIAuthSession?) {
        self.session = session
    }

    func load() throws -> WAIAuthSession? {
        if loadError {
            throw WAISecureAccessStoreError.invalidValue
        }
        return session
    }

    func save(_ session: WAIAuthSession) throws {
        if saveError {
            throw WAISecureAccessStoreError.invalidValue
        }
        self.session = session
    }

    func clear() throws {
        clearCount += 1
        if clearError {
            throw WAISecureAccessStoreError.invalidValue
        }
        session = nil
    }
}
