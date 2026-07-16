import Foundation
import Testing
@testable import WAI

@MainActor
struct WAIAccessControllerTests {
    private let userID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let otherUserID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let verifiedAt = Date(timeIntervalSince1970: 1_784_112_400)
    private let approvedAt = Date(timeIntervalSince1970: 1_784_108_800)

    @Test func restoreWithoutSessionOrGrantRequiresSignIn() async {
        let fixture = makeFixture()

        await fixture.controller.restoreAccess()

        #expect(fixture.controller.state == .signedOut)
        #expect(fixture.sensitiveData.clearCount == 0)
    }

    @Test func interruptedAccountDeletionFailsClosedOnNextLaunch() async {
        let fixture = makeFixture(
            grant: makeGrant(userID: userID),
            deletionIntent: WAIAccountDeletionIntent(
                userID: userID,
                startedAt: verifiedAt.addingTimeInterval(-60)
            )
        )
        fixture.authentication.restoredSession = makeSession(userID: userID)

        await fixture.controller.restoreAccess()

        #expect(fixture.controller.state == .signedOut)
        #expect(fixture.authentication.signOutCount == 1)
        #expect(fixture.authentication.profileFetchCount == 0)
        #expect(fixture.approvalStore.grant == nil)
        #expect(fixture.deletionIntentStore.intent == nil)
        #expect(fixture.sensitiveData.clearCount == 1)
    }

    @Test func interruptedAccountDeletionClearsLocalAccessBeforeRemoteCallCompletes() async {
        let fixture = makeFixture(
            grant: makeGrant(userID: userID),
            deletionIntent: WAIAccountDeletionIntent(
                userID: userID,
                startedAt: verifiedAt.addingTimeInterval(-60)
            )
        )
        fixture.authentication.restoredSession = makeSession(userID: userID)
        fixture.authentication.shouldSuspendSignOut = true

        let restore = Task {
            await fixture.controller.restoreAccess()
        }
        while fixture.authentication.signOutCount == 0 {
            await Task.yield()
        }

        #expect(fixture.controller.state == .signingOut)
        #expect(fixture.approvalStore.grant == nil)
        #expect(fixture.sensitiveData.clearCount == 1)
        #expect(fixture.deletionIntentStore.intent != nil)

        fixture.authentication.resumeSignOut()
        await restore.value

        #expect(fixture.controller.state == .signedOut)
        #expect(fixture.deletionIntentStore.intent == nil)
    }

    @Test func interruptedSignOutFinishesBeforeRestoringAccess() async {
        let fixture = makeFixture(
            grant: makeGrant(userID: userID),
            signOutIntent: WAILocalSignOutIntent(
                userID: userID,
                startedAt: verifiedAt.addingTimeInterval(-60)
            )
        )
        fixture.authentication.restoredSession = makeSession(userID: userID)

        await fixture.controller.restoreAccess()

        #expect(fixture.controller.state == .signedOut)
        #expect(fixture.authentication.signOutCount == 1)
        #expect(fixture.authentication.profileFetchCount == 0)
        #expect(fixture.approvalStore.grant == nil)
        #expect(fixture.signOutIntentStore.intent == nil)
        #expect(fixture.sensitiveData.clearCount == 1)
    }

    @Test func approvedProfileCreatesOnlineAndOfflineGrant() async {
        let fixture = makeFixture()
        let session = makeSession(userID: userID)
        fixture.authentication.restoredSession = session
        fixture.authentication.profile = makeProfile(
            userID: userID,
            status: .approved
        )

        await fixture.controller.restoreAccess()

        #expect(
            fixture.controller.state == .approved(
                WAIApprovedAccess(
                    userID: userID,
                    mode: .online,
                    lastVerifiedAt: verifiedAt
                )
            )
        )
        #expect(
            fixture.approvalStore.grant == WAIOfflineApprovalGrant(
                userID: userID,
                approvedAt: approvedAt,
                lastVerifiedAt: verifiedAt
            )
        )
    }

    @Test func pendingProfileRemovesEarlierConfidentialAccess() async {
        let fixture = makeFixture(
            grant: makeGrant(userID: userID)
        )
        fixture.authentication.restoredSession = makeSession(userID: userID)
        fixture.authentication.profile = makeProfile(
            userID: userID,
            status: .pending
        )

        await fixture.controller.restoreAccess()

        #expect(
            fixture.controller.state == .pending(
                WAIPendingAccess(
                    userID: userID,
                    approvalCode: "A1B2C3D4E5F6"
                )
            )
        )
        #expect(fixture.approvalStore.grant == nil)
        #expect(fixture.sensitiveData.clearCount == 1)
    }

    @Test func revokedProfileRemovesOfflineGrantAndData() async {
        let fixture = makeFixture(
            grant: makeGrant(userID: userID)
        )
        fixture.authentication.restoredSession = makeSession(userID: userID)
        fixture.authentication.profile = makeProfile(
            userID: userID,
            status: .revoked
        )

        await fixture.controller.restoreAccess()

        #expect(fixture.controller.state == .revoked)
        #expect(fixture.approvalStore.grant == nil)
        #expect(fixture.sensitiveData.clearCount == 1)
    }

    @Test func foregroundRefreshDetectsRevocationAndClearsData() async {
        let fixture = makeFixture()
        fixture.authentication.restoredSession = makeSession(userID: userID)
        fixture.authentication.profile = makeProfile(
            userID: userID,
            status: .approved
        )

        await fixture.controller.restoreAccess()

        fixture.authentication.profile = makeProfile(
            userID: userID,
            status: .revoked
        )
        await fixture.controller.refreshAccess()

        #expect(fixture.controller.state == .revoked)
        #expect(fixture.approvalStore.grant == nil)
        #expect(fixture.sensitiveData.clearCount == 1)
        #expect(fixture.authentication.profileFetchCount == 2)
    }

    @Test func foregroundRefreshKeepsVerifiedOfflineAccessOnNetworkFailure() async {
        let fixture = makeFixture()
        fixture.authentication.restoredSession = makeSession(userID: userID)
        fixture.authentication.profile = makeProfile(
            userID: userID,
            status: .approved
        )

        await fixture.controller.restoreAccess()

        fixture.authentication.profileError = .networkUnavailable
        await fixture.controller.refreshAccess()

        #expect(
            fixture.controller.state == .approved(
                WAIApprovedAccess(
                    userID: userID,
                    mode: .offline(.networkUnavailable),
                    lastVerifiedAt: verifiedAt
                )
            )
        )
        #expect(fixture.approvalStore.grant == makeGrant(userID: userID))
        #expect(fixture.sensitiveData.clearCount == 0)
        #expect(fixture.authentication.profileFetchCount == 2)
    }

    @Test func approvedUserKeepsAccessDuringNetworkFailure() async {
        let fixture = makeFixture(
            grant: makeGrant(userID: userID)
        )
        fixture.authentication.restoredSession = makeSession(userID: userID)
        fixture.authentication.profileError = .networkUnavailable

        await fixture.controller.restoreAccess()

        #expect(
            fixture.controller.state == .approved(
                WAIApprovedAccess(
                    userID: userID,
                    mode: .offline(.networkUnavailable),
                    lastVerifiedAt: verifiedAt
                )
            )
        )
    }

    @Test func malformedAuthenticatedResponseFailsClosed() async {
        let fixture = makeFixture(
            grant: makeGrant(userID: userID)
        )
        fixture.authentication.restoredSession = makeSession(userID: userID)
        fixture.authentication.profileError = .invalidResponse

        await fixture.controller.restoreAccess()

        #expect(fixture.controller.state == .failed(.invalidServerResponse))
        #expect(fixture.approvalStore.grant == nil)
        #expect(fixture.sensitiveData.clearCount == 1)
    }

    @Test func offlineGrantAllowsMissingSessionInsideSevenDayWindow() async {
        let fixture = makeFixture(
            grant: makeGrant(userID: userID)
        )

        await fixture.controller.restoreAccess()

        #expect(
            fixture.controller.state == .approved(
                WAIApprovedAccess(
                    userID: userID,
                    mode: .offline(.sessionUnavailable),
                    lastVerifiedAt: verifiedAt
                )
            )
        )
    }

    @Test func offlineGrantAllowsExactSevenDayBoundary() async {
        let fixture = makeFixture(
            grant: makeGrant(userID: userID),
            now: verifiedAt.addingTimeInterval(
                WAIOfflineAccessPolicy.maximumAge
            )
        )

        await fixture.controller.restoreAccess()

        #expect(
            fixture.controller.state == .approved(
                WAIApprovedAccess(
                    userID: userID,
                    mode: .offline(.sessionUnavailable),
                    lastVerifiedAt: verifiedAt
                )
            )
        )
    }

    @Test func expiredOfflineGrantFailsClosedAndClearsData() async {
        let fixture = makeFixture(
            grant: makeGrant(userID: userID),
            now: verifiedAt.addingTimeInterval(
                WAIOfflineAccessPolicy.maximumAge + 1
            )
        )

        await fixture.controller.restoreAccess()

        #expect(fixture.controller.state == .failed(.authentication))
        #expect(fixture.approvalStore.grant == nil)
        #expect(fixture.sensitiveData.clearCount == 1)
    }

    @Test func futureDatedOfflineGrantFailsClosedAndClearsData() async {
        let fixture = makeFixture(
            grant: makeGrant(userID: userID),
            now: verifiedAt.addingTimeInterval(-1)
        )

        await fixture.controller.restoreAccess()

        #expect(fixture.controller.state == .failed(.authentication))
        #expect(fixture.approvalStore.grant == nil)
        #expect(fixture.sensitiveData.clearCount == 1)
    }

    @Test func anotherAccountCannotUseExistingOfflineGrant() async {
        let fixture = makeFixture(
            grant: makeGrant(userID: userID)
        )
        fixture.authentication.restoredSession = makeSession(userID: otherUserID)
        fixture.authentication.profileError = .networkUnavailable

        await fixture.controller.restoreAccess()

        #expect(fixture.controller.state == .failed(.serviceUnavailable))
        #expect(fixture.approvalStore.grant == nil)
        #expect(fixture.sensitiveData.clearCount == 1)
    }

    @Test func mismatchedProfileFailsClosedAndClearsData() async {
        let fixture = makeFixture(
            grant: makeGrant(userID: userID)
        )
        fixture.authentication.restoredSession = makeSession(userID: userID)
        fixture.authentication.profile = makeProfile(
            userID: otherUserID,
            status: .approved
        )

        await fixture.controller.restoreAccess()

        #expect(fixture.controller.state == .failed(.invalidServerResponse))
        #expect(fixture.approvalStore.grant == nil)
        #expect(fixture.sensitiveData.clearCount == 1)
    }

    @Test func explicitSignOutAlwaysClearsLocalAuthorization() async {
        let fixture = makeFixture(
            grant: makeGrant(userID: userID)
        )
        fixture.authentication.signOutError = .networkUnavailable

        await fixture.controller.signOut()

        #expect(fixture.controller.state == .signedOut)
        #expect(fixture.approvalStore.grant == nil)
        #expect(fixture.sensitiveData.clearCount == 1)
        #expect(fixture.authentication.signOutCount == 1)
    }

    @Test func signOutClearsLocalAccessBeforeRemoteCallCompletes() async {
        let fixture = makeFixture(
            grant: makeGrant(userID: userID)
        )
        fixture.authentication.restoredSession = makeSession(userID: userID)
        fixture.authentication.profile = makeProfile(
            userID: userID,
            status: .approved
        )
        await fixture.controller.restoreAccess()
        fixture.authentication.shouldSuspendSignOut = true

        let signOut = Task {
            await fixture.controller.signOut()
        }
        while fixture.authentication.signOutCount == 0 {
            await Task.yield()
        }

        #expect(fixture.controller.state == .signingOut)
        #expect(fixture.approvalStore.grant == nil)
        #expect(fixture.sensitiveData.clearCount == 1)
        #expect(fixture.signOutIntentStore.intent != nil)

        fixture.authentication.resumeSignOut()
        await signOut.value

        #expect(fixture.controller.state == .signedOut)
        #expect(fixture.signOutIntentStore.intent == nil)
    }

    @Test func appleCredentialRevocationClearsSessionGrantAndData() async {
        let fixture = makeFixture(
            grant: makeGrant(userID: userID)
        )
        fixture.authentication.restoredSession = makeSession(userID: userID)

        await fixture.controller.handleAppleCredentialRevocation()

        #expect(fixture.controller.state == .signedOut)
        #expect(fixture.approvalStore.grant == nil)
        #expect(fixture.sensitiveData.clearCount == 1)
        #expect(fixture.authentication.signOutCount == 1)
    }

    @Test func secureSessionClearFailureIsNotHiddenDuringSignOut() async {
        let fixture = makeFixture(
            grant: makeGrant(userID: userID)
        )
        fixture.authentication.signOutError = .secureStorage

        await fixture.controller.signOut()

        #expect(fixture.controller.state == .failed(.secureStorage))
        #expect(fixture.approvalStore.grant == nil)
        #expect(fixture.sensitiveData.clearCount == 1)
    }

    @Test func confirmedAccountDeletionClearsAllLocalAccess() async {
        let fixture = makeFixture()
        fixture.authentication.restoredSession = makeSession(userID: userID)
        fixture.authentication.profile = makeProfile(
            userID: userID,
            status: .approved
        )
        await fixture.controller.restoreAccess()

        let result = await fixture.controller.deleteAccount(
            with: deletionCredential()
        )

        #expect(result == .deleted)
        #expect(fixture.controller.state == .signedOut)
        #expect(fixture.authentication.deletedUserID == userID)
        #expect(fixture.approvalStore.grant == nil)
        #expect(fixture.deletionIntentStore.saveCount == 1)
        #expect(fixture.deletionIntentStore.intent == nil)
        #expect(fixture.sensitiveData.clearCount == 1)
    }

    @Test func pendingAccountCanAlsoBeDeleted() async {
        let fixture = makeFixture()
        fixture.authentication.restoredSession = makeSession(userID: userID)
        fixture.authentication.profile = makeProfile(
            userID: userID,
            status: .pending
        )
        await fixture.controller.restoreAccess()

        let result = await fixture.controller.deleteAccount(
            with: deletionCredential()
        )

        #expect(result == .deleted)
        #expect(fixture.controller.state == .signedOut)
        #expect(fixture.authentication.deletedUserID == userID)
        #expect(fixture.approvalStore.grant == nil)
    }

    @Test func revokedAccountCanStillBeDeleted() async {
        let fixture = makeFixture()
        fixture.authentication.restoredSession = makeSession(userID: userID)
        fixture.authentication.profile = makeProfile(
            userID: userID,
            status: .revoked
        )
        await fixture.controller.restoreAccess()

        let result = await fixture.controller.deleteAccount(
            with: deletionCredential()
        )

        #expect(result == .deleted)
        #expect(fixture.controller.state == .signedOut)
        #expect(fixture.authentication.deletedUserID == userID)
    }

    @Test func lostDeletionResponseFailsClosedAndKeepsIntent() async {
        let fixture = makeFixture()
        fixture.authentication.restoredSession = makeSession(userID: userID)
        fixture.authentication.profile = makeProfile(
            userID: userID,
            status: .approved
        )
        await fixture.controller.restoreAccess()
        fixture.authentication.deleteError = .networkUnavailable

        let result = await fixture.controller.deleteAccount(
            with: deletionCredential()
        )

        #expect(result == .failed(.connection))
        #expect(fixture.controller.state == .failed(.authentication))
        #expect(fixture.approvalStore.grant == nil)
        #expect(fixture.deletionIntentStore.saveCount == 1)
        #expect(fixture.deletionIntentStore.intent != nil)
        #expect(fixture.sensitiveData.clearCount == 1)
        #expect(fixture.authentication.signOutCount == 1)
    }

    @Test func lostDeletionResponseClearsLocalAccessBeforeRemoteSignOutCompletes() async {
        let fixture = makeFixture()
        fixture.authentication.restoredSession = makeSession(userID: userID)
        fixture.authentication.profile = makeProfile(
            userID: userID,
            status: .approved
        )
        await fixture.controller.restoreAccess()
        fixture.authentication.deleteError = .networkUnavailable
        fixture.authentication.shouldSuspendSignOut = true

        let deletion = Task {
            await fixture.controller.deleteAccount(
                with: deletionCredential()
            )
        }
        while fixture.authentication.signOutCount == 0 {
            await Task.yield()
        }

        #expect(fixture.approvalStore.grant == nil)
        #expect(fixture.sensitiveData.clearCount == 1)
        #expect(fixture.deletionIntentStore.intent != nil)

        fixture.authentication.resumeSignOut()
        let result = await deletion.value

        #expect(result == .failed(.connection))
        #expect(fixture.controller.state == .failed(.authentication))
    }

    @Test func explicitDeletionRejectionPreservesApprovedAccess() async {
        let fixture = makeFixture()
        fixture.authentication.restoredSession = makeSession(userID: userID)
        fixture.authentication.profile = makeProfile(
            userID: userID,
            status: .approved
        )
        await fixture.controller.restoreAccess()
        let approvedState = fixture.controller.state
        fixture.authentication.deleteError = .authenticationFailed

        let result = await fixture.controller.deleteAccount(
            with: deletionCredential()
        )

        #expect(result == .failed(.authentication))
        #expect(fixture.controller.state == approvedState)
        #expect(fixture.approvalStore.grant != nil)
        #expect(fixture.deletionIntentStore.intent == nil)
        #expect(fixture.sensitiveData.clearCount == 0)
        #expect(fixture.authentication.signOutCount == 0)
    }

    @Test func invalidAccountDeletionResponseFailsClosed() async {
        let fixture = makeFixture()
        fixture.authentication.restoredSession = makeSession(userID: userID)
        fixture.authentication.profile = makeProfile(
            userID: userID,
            status: .approved
        )
        await fixture.controller.restoreAccess()
        fixture.authentication.deleteError = .invalidResponse

        let result = await fixture.controller.deleteAccount(
            with: deletionCredential()
        )

        #expect(result == .failed(.invalidServerResponse))
        #expect(fixture.controller.state == .failed(.invalidServerResponse))
        #expect(fixture.approvalStore.grant == nil)
        #expect(fixture.deletionIntentStore.intent != nil)
        #expect(fixture.sensitiveData.clearCount == 1)
        #expect(fixture.authentication.signOutCount == 1)
    }

    @Test func accountDeletionCannotStartWithoutFreshAppleCode() async {
        let fixture = makeFixture()
        fixture.authentication.restoredSession = makeSession(userID: userID)
        fixture.authentication.profile = makeProfile(
            userID: userID,
            status: .approved
        )
        await fixture.controller.restoreAccess()
        let approvedState = fixture.controller.state

        let result = await fixture.controller.deleteAccount(
            with: WAIAppleSignInCredential(
                identityToken: "identity-token",
                rawNonce: "raw-nonce"
            )
        )

        #expect(result == .failed(.authentication))
        #expect(fixture.controller.state == approvedState)
        #expect(fixture.authentication.deleteCount == 0)
    }

    @Test func invalidApprovalCodeIsRejected() {
        let profile = WAIUserProfile(
            id: userID,
            approvalCode: "NOT-A-CODE",
            accessStatus: .pending,
            createdAt: approvedAt,
            approvedAt: nil,
            revokedAt: nil
        )

        #expect(!profile.isValid)
    }

    @Test func offlineGrantReadFailureIsReportedAsSecureStorage() async {
        let fixture = makeFixture()
        fixture.approvalStore.loadError = true

        await fixture.controller.restoreAccess()

        #expect(fixture.controller.state == .failed(.secureStorage))
    }

    private func makeFixture(
        grant: WAIOfflineApprovalGrant? = nil,
        deletionIntent: WAIAccountDeletionIntent? = nil,
        signOutIntent: WAILocalSignOutIntent? = nil,
        now: Date? = nil
    ) -> AccessFixture {
        let authentication = StubWAIAuthenticationService()
        let approvalStore = InMemoryOfflineApprovalStore(grant: grant)
        let deletionIntentStore = InMemoryAccountDeletionIntentStore(
            intent: deletionIntent
        )
        let signOutIntentStore = InMemoryLocalSignOutIntentStore(
            intent: signOutIntent
        )
        let sensitiveData = SensitiveDataStoreSpy()
        let controller = WAIAccessController(
            authenticationService: authentication,
            approvalStore: approvalStore,
            deletionIntentStore: deletionIntentStore,
            signOutIntentStore: signOutIntentStore,
            sensitiveDataStore: sensitiveData,
            now: { now ?? verifiedAt }
        )
        return AccessFixture(
            controller: controller,
            authentication: authentication,
            approvalStore: approvalStore,
            deletionIntentStore: deletionIntentStore,
            signOutIntentStore: signOutIntentStore,
            sensitiveData: sensitiveData
        )
    }

    private func makeSession(userID: UUID) -> WAIAuthSession {
        WAIAuthSession(
            userID: userID,
            accessToken: "access-token",
            refreshToken: "refresh-token",
            expiresAt: verifiedAt.addingTimeInterval(3_600)
        )
    }

    private func makeGrant(userID: UUID) -> WAIOfflineApprovalGrant {
        WAIOfflineApprovalGrant(
            userID: userID,
            approvedAt: approvedAt,
            lastVerifiedAt: verifiedAt
        )
    }

    private func makeProfile(
        userID: UUID,
        status: WAIProfileAccessStatus
    ) -> WAIUserProfile {
        WAIUserProfile(
            id: userID,
            approvalCode: "A1B2C3D4E5F6",
            accessStatus: status,
            createdAt: approvedAt.addingTimeInterval(-3_600),
            approvedAt: status == .approved ? approvedAt : nil,
            revokedAt: status == .revoked ? verifiedAt : nil
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

@MainActor
private struct AccessFixture {
    let controller: WAIAccessController
    let authentication: StubWAIAuthenticationService
    let approvalStore: InMemoryOfflineApprovalStore
    let deletionIntentStore: InMemoryAccountDeletionIntentStore
    let signOutIntentStore: InMemoryLocalSignOutIntentStore
    let sensitiveData: SensitiveDataStoreSpy
}

private final class StubWAIAuthenticationService: WAIAuthenticationServicing {
    var restoredSession: WAIAuthSession?
    var restoreError: WAIAuthenticationServiceError?
    var signedInSession: WAIAuthSession?
    var signInError: WAIAuthenticationServiceError?
    var profile: WAIUserProfile?
    var profileError: WAIAuthenticationServiceError?
    var signOutError: WAIAuthenticationServiceError?
    var deleteError: WAIAuthenticationServiceError?
    var shouldSuspendSignOut = false
    private(set) var signOutCount = 0
    private(set) var profileFetchCount = 0
    private(set) var deleteCount = 0
    private(set) var deletedUserID: UUID?
    private var signOutContinuation: CheckedContinuation<Void, Never>?

    func restoreSession() async throws -> WAIAuthSession? {
        if let restoreError {
            throw restoreError
        }
        return restoredSession
    }

    func validSession() async throws -> WAIAuthSession {
        if let restoreError {
            throw restoreError
        }
        guard let session = restoredSession ?? signedInSession else {
            throw WAIAuthenticationServiceError.sessionUnavailable
        }
        return session
    }

    func signInWithApple(
        credential: WAIAppleSignInCredential
    ) async throws -> WAIAuthSession {
        if let signInError {
            throw signInError
        }
        guard let signedInSession else {
            throw WAIAuthenticationServiceError.invalidResponse
        }
        return signedInSession
    }

    func fetchProfile(for session: WAIAuthSession) async throws -> WAIUserProfile {
        profileFetchCount += 1
        if let profileError {
            throw profileError
        }
        guard let profile else {
            throw WAIAuthenticationServiceError.invalidResponse
        }
        return profile
    }

    func deleteAccount(
        credential: WAIAppleSignInCredential,
        expectedUserID: UUID
    ) async throws {
        deleteCount += 1
        deletedUserID = expectedUserID
        if let deleteError {
            throw deleteError
        }
    }

    func signOut(session: WAIAuthSession?) async throws {
        signOutCount += 1
        if shouldSuspendSignOut {
            await withCheckedContinuation { continuation in
                signOutContinuation = continuation
            }
        }
        if let signOutError {
            throw signOutError
        }
    }

    func resumeSignOut() {
        signOutContinuation?.resume()
        signOutContinuation = nil
    }
}

private final class InMemoryOfflineApprovalStore: WAIOfflineApprovalStoring {
    var grant: WAIOfflineApprovalGrant?
    var loadError = false

    init(grant: WAIOfflineApprovalGrant?) {
        self.grant = grant
    }

    func load() throws -> WAIOfflineApprovalGrant? {
        if loadError {
            throw WAISecureAccessStoreError.invalidValue
        }
        return grant
    }

    func save(_ grant: WAIOfflineApprovalGrant) throws {
        self.grant = grant
    }

    func clear() throws {
        grant = nil
    }
}

private final class InMemoryAccountDeletionIntentStore:
    WAIAccountDeletionIntentStoring
{
    var intent: WAIAccountDeletionIntent?
    var loadError = false
    var saveError = false
    var clearError = false
    private(set) var saveCount = 0

    init(intent: WAIAccountDeletionIntent?) {
        self.intent = intent
    }

    func load() throws -> WAIAccountDeletionIntent? {
        if loadError {
            throw WAISecureAccessStoreError.invalidValue
        }
        return intent
    }

    func save(_ intent: WAIAccountDeletionIntent) throws {
        saveCount += 1
        if saveError {
            throw WAISecureAccessStoreError.invalidValue
        }
        self.intent = intent
    }

    func clear() throws {
        if clearError {
            throw WAISecureAccessStoreError.invalidValue
        }
        intent = nil
    }
}

private final class InMemoryLocalSignOutIntentStore:
    WAILocalSignOutIntentStoring {
    var intent: WAILocalSignOutIntent?

    init(intent: WAILocalSignOutIntent?) {
        self.intent = intent
    }

    func load() throws -> WAILocalSignOutIntent? {
        intent
    }

    func save(_ intent: WAILocalSignOutIntent) throws {
        self.intent = intent
    }

    func clear() throws {
        intent = nil
    }
}

private final class SensitiveDataStoreSpy: WAISensitiveOperationalDataClearing {
    private(set) var clearCount = 0

    func clear() throws {
        clearCount += 1
    }
}
