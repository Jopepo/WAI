import Foundation
import Security

enum WAISecureAccessStoreError: Error, Equatable {
    case keychain(OSStatus)
    case invalidValue
}

struct WAIKeychainDataStore: Sendable {
    private let service: String

    init(service: String = "com.jplabs.WAI.access-control") {
        self.service = service
    }

    func load(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw WAISecureAccessStoreError.keychain(status)
        }
        return data
    }

    func save(_ data: Data, account: String) throws {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(
            identity as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw WAISecureAccessStoreError.keychain(updateStatus)
        }

        var item = identity
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecValueData as String] = data
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw WAISecureAccessStoreError.keychain(addStatus)
        }
    }

    func clear(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw WAISecureAccessStoreError.keychain(status)
        }
    }
}

final class KeychainWAIAuthSessionStore: WAIAuthSessionStoring {
    private let account = "auth-session-v1"
    private let keychain = WAIKeychainDataStore()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func load() throws -> WAIAuthSession? {
        guard let data = try keychain.load(account: account) else {
            return nil
        }
        let session = try decoder.decode(WAIAuthSession.self, from: data)
        guard session.isValid else {
            throw WAISecureAccessStoreError.invalidValue
        }
        return session
    }

    func save(_ session: WAIAuthSession) throws {
        guard session.isValid else {
            throw WAISecureAccessStoreError.invalidValue
        }
        try keychain.save(try encoder.encode(session), account: account)
    }

    func clear() throws {
        try keychain.clear(account: account)
    }
}

final class KeychainWAIOfflineApprovalStore: WAIOfflineApprovalStoring {
    private let account = "offline-approval-v1"
    private let keychain = WAIKeychainDataStore()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func load() throws -> WAIOfflineApprovalGrant? {
        guard let data = try keychain.load(account: account) else {
            return nil
        }
        let grant = try decoder.decode(WAIOfflineApprovalGrant.self, from: data)
        guard grant.isValid else {
            throw WAISecureAccessStoreError.invalidValue
        }
        return grant
    }

    func save(_ grant: WAIOfflineApprovalGrant) throws {
        guard grant.isValid else {
            throw WAISecureAccessStoreError.invalidValue
        }
        try keychain.save(try encoder.encode(grant), account: account)
    }

    func clear() throws {
        try keychain.clear(account: account)
    }
}

final class KeychainWAIAccountDeletionIntentStore:
    WAIAccountDeletionIntentStoring
{
    private let account = "account-deletion-intent-v1"
    private let keychain = WAIKeychainDataStore()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func load() throws -> WAIAccountDeletionIntent? {
        guard let data = try keychain.load(account: account) else {
            return nil
        }
        return try decoder.decode(WAIAccountDeletionIntent.self, from: data)
    }

    func save(_ intent: WAIAccountDeletionIntent) throws {
        try keychain.save(try encoder.encode(intent), account: account)
    }

    func clear() throws {
        try keychain.clear(account: account)
    }
}

final class KeychainWAILocalSignOutIntentStore: WAILocalSignOutIntentStoring {
    private let account = "local-sign-out-intent-v1"
    private let keychain = WAIKeychainDataStore()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func load() throws -> WAILocalSignOutIntent? {
        guard let data = try keychain.load(account: account) else {
            return nil
        }
        return try decoder.decode(WAILocalSignOutIntent.self, from: data)
    }

    func save(_ intent: WAILocalSignOutIntent) throws {
        try keychain.save(try encoder.encode(intent), account: account)
    }

    func clear() throws {
        try keychain.clear(account: account)
    }
}
