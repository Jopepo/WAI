import CryptoKit
import Foundation
import Security

protocol OperationalReleaseKeyStore {
    func loadOrCreateKeyData() throws -> Data
    func deleteKey() throws
}

enum OperationalReleaseKeyStoreError: Error, Equatable {
    case keychain(OSStatus)
    case invalidKeyLength
    case randomGeneration(OSStatus)
}

final class KeychainOperationalReleaseKeyStore: OperationalReleaseKeyStore {
    private let service = "com.jplabs.WAI.operational-data-cache"
    private let account = "encryption-key-v1"
    private let keyByteCount = 32

    func loadOrCreateKeyData() throws -> Data {
        let readQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]

        var result: CFTypeRef?
        let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &result)
        if readStatus == errSecSuccess {
            guard let data = result as? Data, data.count == keyByteCount else {
                throw OperationalReleaseKeyStoreError.invalidKeyLength
            }
            return data
        }
        guard readStatus == errSecItemNotFound else {
            throw OperationalReleaseKeyStoreError.keychain(readStatus)
        }

        var bytes = [UInt8](repeating: 0, count: keyByteCount)
        let randomStatus = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard randomStatus == errSecSuccess else {
            throw OperationalReleaseKeyStoreError.randomGeneration(randomStatus)
        }
        let keyData = Data(bytes)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: keyData
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            return try loadOrCreateKeyData()
        }
        guard addStatus == errSecSuccess else {
            throw OperationalReleaseKeyStoreError.keychain(addStatus)
        }
        return keyData
    }

    func deleteKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OperationalReleaseKeyStoreError.keychain(status)
        }
    }
}

enum ProtectedOperationalReleaseCacheError: Error, Equatable {
    case invalidKeyLength
    case missingEncryptedRepresentation
    case unknownDatasetKey(String)
    case ownerMismatch
    case fileTooLarge
    case operationInvalidated
}

struct OperationalReleaseRefreshToken: @unchecked Sendable {
    fileprivate let fence: OperationalReleaseAccessFence
    fileprivate let generation: UInt64
}

final class OperationalReleaseAccessFence: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func makeToken() -> OperationalReleaseRefreshToken {
        lock.lock()
        defer { lock.unlock() }
        return OperationalReleaseRefreshToken(
            fence: self,
            generation: generation
        )
    }

    func invalidate() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }

    fileprivate func accepts(_ token: OperationalReleaseRefreshToken) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return token.fence === self && token.generation == generation
    }
}

private struct CachedOperationalReleaseEnvelope: Codable {
    let ownerUserID: UUID
    let manifest: OperationalReleaseManifest
    let payloads: [String: Data]
}

final class ProtectedOperationalReleaseCache:
    WAISensitiveOperationalDataClearing,
    @unchecked Sendable
{
    static let maximumFileBytes = 8 * 1_024 * 1_024

    private let fileURL: URL
    private let keyStore: OperationalReleaseKeyStore
    private let fileManager: FileManager
    private let accessFence: OperationalReleaseAccessFence
    private let operationLock = NSLock()

    init(
        fileURL: URL,
        keyStore: OperationalReleaseKeyStore,
        accessFence: OperationalReleaseAccessFence =
            OperationalReleaseAccessFence(),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.keyStore = keyStore
        self.accessFence = accessFence
        self.fileManager = fileManager
    }

    func makeRefreshToken() -> OperationalReleaseRefreshToken {
        accessFence.makeToken()
    }

    func validateRefreshToken(
        _ token: OperationalReleaseRefreshToken
    ) throws {
        guard accessFence.accepts(token) else {
            throw ProtectedOperationalReleaseCacheError.operationInvalidated
        }
    }

    static func production(
        accessFence: OperationalReleaseAccessFence =
            OperationalReleaseAccessFence()
    ) throws -> ProtectedOperationalReleaseCache {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let fileURL = applicationSupport
            .appendingPathComponent("WAI", isDirectory: true)
            .appendingPathComponent("SecureOperationalData", isDirectory: true)
            .appendingPathComponent("release-v1.cache", isDirectory: false)
        return ProtectedOperationalReleaseCache(
            fileURL: fileURL,
            keyStore: KeychainOperationalReleaseKeyStore(),
            accessFence: accessFence
        )
    }

    func save(
        ownerUserID: UUID,
        manifest: OperationalReleaseManifest,
        payloads: [OperationalDatasetKey: Data],
        refreshToken: OperationalReleaseRefreshToken? = nil
    ) throws {
        try OperationalReleaseValidator.validatePackage(
            manifest: manifest,
            payloads: payloads
        )

        let envelope = CachedOperationalReleaseEnvelope(
            ownerUserID: ownerUserID,
            manifest: manifest,
            payloads: Dictionary(
                uniqueKeysWithValues: payloads.map { ($0.key.rawValue, $0.value) }
            )
        )
        let encoded = try JSONEncoder().encode(envelope)

        operationLock.lock()
        defer { operationLock.unlock() }
        if let refreshToken,
           !accessFence.accepts(refreshToken) {
            throw ProtectedOperationalReleaseCacheError.operationInvalidated
        }

        let key = try encryptionKey()
        let sealed = try AES.GCM.seal(encoded, using: key)
        guard let combined = sealed.combined else {
            throw ProtectedOperationalReleaseCacheError.missingEncryptedRepresentation
        }
        guard combined.count <= Self.maximumFileBytes else {
            throw ProtectedOperationalReleaseCacheError.fileTooLarge
        }

        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        try combined.write(
            to: fileURL,
            options: [.atomic, .completeFileProtection]
        )
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: fileURL.path
        )

        var protectedURL = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedURL.setResourceValues(values)
    }

    func load(for ownerUserID: UUID) throws -> (
        manifest: OperationalReleaseManifest,
        payloads: [OperationalDatasetKey: Data]
    )? {
        operationLock.lock()
        defer { operationLock.unlock() }

        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let attributes = try fileManager.attributesOfItem(
            atPath: fileURL.path
        )
        if let size = attributes[.size] as? NSNumber,
           size.intValue > Self.maximumFileBytes {
            throw ProtectedOperationalReleaseCacheError.fileTooLarge
        }

        let encrypted = try Data(contentsOf: fileURL)
        let sealed = try AES.GCM.SealedBox(combined: encrypted)
        let decrypted = try AES.GCM.open(sealed, using: encryptionKey())
        let envelope = try JSONDecoder().decode(
            CachedOperationalReleaseEnvelope.self,
            from: decrypted
        )
        guard envelope.ownerUserID == ownerUserID else {
            throw ProtectedOperationalReleaseCacheError.ownerMismatch
        }

        var payloads: [OperationalDatasetKey: Data] = [:]
        for (rawKey, data) in envelope.payloads {
            guard let key = OperationalDatasetKey(rawValue: rawKey) else {
                throw ProtectedOperationalReleaseCacheError.unknownDatasetKey(rawKey)
            }
            payloads[key] = data
        }
        try OperationalReleaseValidator.validatePackage(
            manifest: envelope.manifest,
            payloads: payloads
        )
        return (envelope.manifest, payloads)
    }

    func clear() throws {
        accessFence.invalidate()
        try discardInvalidContents()
    }

    func discardInvalidContents() throws {
        operationLock.lock()
        defer { operationLock.unlock() }

        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
        try keyStore.deleteKey()
    }

    private func encryptionKey() throws -> SymmetricKey {
        let keyData = try keyStore.loadOrCreateKeyData()
        guard keyData.count == 32 else {
            throw ProtectedOperationalReleaseCacheError.invalidKeyLength
        }
        return SymmetricKey(data: keyData)
    }
}
