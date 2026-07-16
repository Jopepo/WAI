import Foundation
import Security
import Testing
@testable import WAI

@Suite(.serialized)
struct EncryptionKeyStoreTests {
    private let keyAccount = "encryption-key-v1"

    @Test func encryptionKeysAreStableIsolatedAndDeviceOnly() throws {
        let operationalStore = KeychainOperationalReleaseKeyStore()
        let rosterStore = KeychainRosterEncryptionKeyStore()
        let manualService = [
            "com.jplabs.WAI.tests.manual-key",
            UUID().uuidString
        ].joined(separator: ".")
        let manualStore = KeychainManualDataEncryptionKeyStore(
            service: manualService
        )
        let fixtures = [
            KeyStoreFixture(
                service: "com.jplabs.WAI.operational-data-cache",
                load: operationalStore.loadOrCreateKeyData,
                delete: operationalStore.deleteKey
            ),
            KeyStoreFixture(
                service: "com.jplabs.WAI.roster-cache",
                load: rosterStore.loadOrCreateKeyData,
                delete: rosterStore.deleteKey
            ),
            KeyStoreFixture(
                service: manualService,
                load: manualStore.loadOrCreateKeyData,
                delete: manualStore.deleteKey
            )
        ]

        try fixtures.forEach { try $0.delete() }
        defer {
            fixtures.forEach { try? $0.delete() }
        }

        var initialKeys: [Data] = []
        for fixture in fixtures {
            let key = try fixture.load()
            #expect(key.count == 32)
            #expect(try fixture.load() == key)
            try expectDeviceOnlyKeychainItem(
                service: fixture.service,
                account: keyAccount
            )
            initialKeys.append(key)
        }
        #expect(Set(initialKeys).count == fixtures.count)

        for (fixture, initialKey) in zip(fixtures, initialKeys) {
            try fixture.delete()
            #expect(
                try keychainAttributes(
                    service: fixture.service,
                    account: keyAccount
                ) == nil
            )
            try fixture.delete()

            let replacementKey = try fixture.load()
            #expect(replacementKey.count == 32)
            #expect(replacementKey != initialKey)
            try expectDeviceOnlyKeychainItem(
                service: fixture.service,
                account: keyAccount
            )
        }
    }

    @Test func malformedEncryptionKeysFailClosed() throws {
        let operationalService = "com.jplabs.WAI.operational-data-cache"
        let rosterService = "com.jplabs.WAI.roster-cache"
        let manualService = [
            "com.jplabs.WAI.tests.invalid-manual-key",
            UUID().uuidString
        ].joined(separator: ".")
        let operationalStore = KeychainOperationalReleaseKeyStore()
        let rosterStore = KeychainRosterEncryptionKeyStore()
        let manualStore = KeychainManualDataEncryptionKeyStore(
            service: manualService
        )
        let rawStores = [
            WAIKeychainDataStore(service: operationalService),
            WAIKeychainDataStore(service: rosterService),
            WAIKeychainDataStore(service: manualService)
        ]

        try operationalStore.deleteKey()
        try rosterStore.deleteKey()
        try manualStore.deleteKey()
        defer {
            try? operationalStore.deleteKey()
            try? rosterStore.deleteKey()
            try? manualStore.deleteKey()
        }

        for rawStore in rawStores {
            try rawStore.save(
                Data(repeating: 0x7F, count: 31),
                account: keyAccount
            )
        }

        #expect(throws: OperationalReleaseKeyStoreError.invalidKeyLength) {
            try operationalStore.loadOrCreateKeyData()
        }
        #expect(throws: RosterEncryptionKeyStoreError.invalidKeyLength) {
            try rosterStore.loadOrCreateKeyData()
        }
        #expect(throws: ManualDataEncryptionKeyStoreError.invalidKeyLength) {
            try manualStore.loadOrCreateKeyData()
        }
    }

    private func expectDeviceOnlyKeychainItem(
        service: String,
        account: String
    ) throws {
        let attributes = try #require(
            try keychainAttributes(service: service, account: account)
        )
        #expect(
            attributes[kSecAttrAccessible as String] as? String
            == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool != true)
    }

    private func keychainAttributes(
        service: String,
        account: String
    ) throws -> [String: Any]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess,
              let attributes = result as? [String: Any] else {
            throw KeychainAttributeTestError.read(status)
        }
        return attributes
    }
}

private struct KeyStoreFixture {
    let service: String
    let load: () throws -> Data
    let delete: () throws -> Void
}

private enum KeychainAttributeTestError: Error {
    case read(OSStatus)
}
