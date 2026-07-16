import Foundation
import Testing
@testable import WAI

@Suite(.serialized)
struct SecureAccessPersistenceTests {
    @Test func invalidAuthorizationValuesNeverReachKeychain() throws {
        let authStore = KeychainWAIAuthSessionStore()
        let approvalStore = KeychainWAIOfflineApprovalStore()
        try authStore.clear()
        try approvalStore.clear()
        defer {
            try? authStore.clear()
            try? approvalStore.clear()
        }

        let userID = UUID(
            uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        )!
        let now = Date(timeIntervalSince1970: 1_784_112_400)
        let invalidSession = WAIAuthSession(
            userID: userID,
            accessToken: "",
            refreshToken: "refresh-token",
            expiresAt: now.addingTimeInterval(3_600)
        )
        let invalidGrant = WAIOfflineApprovalGrant(
            userID: userID,
            approvedAt: now,
            lastVerifiedAt: now.addingTimeInterval(-1)
        )

        #expect(throws: WAISecureAccessStoreError.invalidValue) {
            try authStore.save(invalidSession)
        }
        #expect(throws: WAISecureAccessStoreError.invalidValue) {
            try approvalStore.save(invalidGrant)
        }
        #expect(try authStore.load() == nil)
        #expect(try approvalStore.load() == nil)
    }

    @Test func realKeychainStoresRoundTripUpdateAndStayIsolated() throws {
        let authStore = KeychainWAIAuthSessionStore()
        let approvalStore = KeychainWAIOfflineApprovalStore()
        let deletionStore = KeychainWAIAccountDeletionIntentStore()
        let signOutStore = KeychainWAILocalSignOutIntentStore()

        try clear(
            authStore: authStore,
            approvalStore: approvalStore,
            deletionStore: deletionStore,
            signOutStore: signOutStore
        )
        defer {
            try? clear(
                authStore: authStore,
                approvalStore: approvalStore,
                deletionStore: deletionStore,
                signOutStore: signOutStore
            )
        }

        let userID = UUID(
            uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        )!
        let approvedAt = Date(timeIntervalSince1970: 1_784_108_800)
        let verifiedAt = Date(timeIntervalSince1970: 1_784_112_400)
        let initialSession = WAIAuthSession(
            userID: userID,
            accessToken: "access-token-1",
            refreshToken: "refresh-token-1",
            expiresAt: verifiedAt.addingTimeInterval(3_600)
        )
        let refreshedSession = WAIAuthSession(
            userID: userID,
            accessToken: "access-token-2",
            refreshToken: "refresh-token-2",
            expiresAt: verifiedAt.addingTimeInterval(7_200)
        )
        let grant = WAIOfflineApprovalGrant(
            userID: userID,
            approvedAt: approvedAt,
            lastVerifiedAt: verifiedAt
        )
        let deletionIntent = WAIAccountDeletionIntent(
            userID: userID,
            startedAt: verifiedAt.addingTimeInterval(60)
        )
        let signOutIntent = WAILocalSignOutIntent(
            userID: userID,
            startedAt: verifiedAt.addingTimeInterval(120)
        )

        #expect(try authStore.load() == nil)
        #expect(try approvalStore.load() == nil)
        #expect(try deletionStore.load() == nil)
        #expect(try signOutStore.load() == nil)

        try authStore.save(initialSession)
        try approvalStore.save(grant)
        try deletionStore.save(deletionIntent)
        try signOutStore.save(signOutIntent)

        #expect(try authStore.load() == initialSession)
        #expect(try approvalStore.load() == grant)
        #expect(try deletionStore.load() == deletionIntent)
        #expect(try signOutStore.load() == signOutIntent)

        try authStore.save(refreshedSession)
        #expect(try authStore.load() == refreshedSession)

        try authStore.clear()
        #expect(try authStore.load() == nil)
        #expect(try approvalStore.load() == grant)
        #expect(try deletionStore.load() == deletionIntent)
        #expect(try signOutStore.load() == signOutIntent)

        try authStore.clear()
    }

    private func clear(
        authStore: KeychainWAIAuthSessionStore,
        approvalStore: KeychainWAIOfflineApprovalStore,
        deletionStore: KeychainWAIAccountDeletionIntentStore,
        signOutStore: KeychainWAILocalSignOutIntentStore
    ) throws {
        try authStore.clear()
        try approvalStore.clear()
        try deletionStore.clear()
        try signOutStore.clear()
    }
}
