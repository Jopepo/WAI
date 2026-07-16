import CryptoKit
import Foundation
import Security

enum WAIManualDataStoreState: Equatable, Sendable {
    case idle
    case ready
    case failedSecureStorage
}

protocol ManualDataEncryptionKeyStoring {
    func loadOrCreateKeyData() throws -> Data
    func deleteKey() throws
}

enum ManualDataEncryptionKeyStoreError: Error, Equatable {
    case invalidKeyLength
    case randomGeneration(OSStatus)
}

final class KeychainManualDataEncryptionKeyStore:
    ManualDataEncryptionKeyStoring
{
    private let account = "encryption-key-v1"
    private let keyByteCount = 32
    private let keychain: WAIKeychainDataStore

    init(service: String) {
        keychain = WAIKeychainDataStore(service: service)
    }

    func loadOrCreateKeyData() throws -> Data {
        if let data = try keychain.load(account: account) {
            guard data.count == keyByteCount else {
                throw ManualDataEncryptionKeyStoreError.invalidKeyLength
            }
            return data
        }

        var bytes = [UInt8](repeating: 0, count: keyByteCount)
        let status = SecRandomCopyBytes(
            kSecRandomDefault,
            bytes.count,
            &bytes
        )
        guard status == errSecSuccess else {
            throw ManualDataEncryptionKeyStoreError.randomGeneration(status)
        }
        let data = Data(bytes)
        try keychain.save(data, account: account)
        return data
    }

    func deleteKey() throws {
        try keychain.clear(account: account)
    }
}

enum ProtectedManualDataStoreError: Error, Equatable {
    case invalidKeyLength
    case missingEncryptedRepresentation
    case ownerMismatch
    case invalidEnvelope
    case fileTooLarge
}

private struct ProtectedManualDataEnvelope<Value: Codable>: Codable {
    static var currentSchemaVersion: Int { 1 }

    let schemaVersion: Int
    let ownerUserID: UUID
    let value: Value
}

final class ProtectedOwnerBoundManualDataStore<Value: Codable>:
    WAISensitiveOperationalDataClearing
{
    private let maximumFileBytes: Int
    private let fileURL: URL
    private let keyStore: ManualDataEncryptionKeyStoring
    private let fileManager: FileManager

    init(
        fileURL: URL,
        keyStore: ManualDataEncryptionKeyStoring,
        maximumFileBytes: Int = 524_288,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.keyStore = keyStore
        self.maximumFileBytes = maximumFileBytes
        self.fileManager = fileManager
    }

    func load(for ownerUserID: UUID) throws -> Value? {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        if let size = attributes[.size] as? NSNumber,
           size.intValue > maximumFileBytes {
            throw ProtectedManualDataStoreError.fileTooLarge
        }

        let encrypted = try Data(contentsOf: fileURL)
        let sealed = try AES.GCM.SealedBox(combined: encrypted)
        let decrypted = try AES.GCM.open(sealed, using: encryptionKey())
        let envelope = try JSONDecoder().decode(
            ProtectedManualDataEnvelope<Value>.self,
            from: decrypted
        )
        guard envelope.schemaVersion
                == ProtectedManualDataEnvelope<Value>.currentSchemaVersion else {
            throw ProtectedManualDataStoreError.invalidEnvelope
        }
        guard envelope.ownerUserID == ownerUserID else {
            throw ProtectedManualDataStoreError.ownerMismatch
        }
        return envelope.value
    }

    func save(_ value: Value, for ownerUserID: UUID) throws {
        let envelope = ProtectedManualDataEnvelope(
            schemaVersion:
                ProtectedManualDataEnvelope<Value>.currentSchemaVersion,
            ownerUserID: ownerUserID,
            value: value
        )
        let encoded = try JSONEncoder().encode(envelope)
        let sealed = try AES.GCM.seal(encoded, using: encryptionKey())
        guard let combined = sealed.combined else {
            throw ProtectedManualDataStoreError.missingEncryptedRepresentation
        }
        guard combined.count <= maximumFileBytes else {
            throw ProtectedManualDataStoreError.fileTooLarge
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

    func clear() throws {
        var firstError: Error?
        if fileManager.fileExists(atPath: fileURL.path) {
            do {
                try fileManager.removeItem(at: fileURL)
            } catch {
                firstError = error
            }
        }

        do {
            try keyStore.deleteKey()
        } catch {
            if firstError == nil {
                firstError = error
            }
        }

        if let firstError {
            throw firstError
        }
    }

    private func encryptionKey() throws -> SymmetricKey {
        let data = try keyStore.loadOrCreateKeyData()
        guard data.count == 32 else {
            throw ProtectedManualDataStoreError.invalidKeyLength
        }
        return SymmetricKey(data: data)
    }
}

func waiSecureManualDataURL(fileName: String) throws -> URL {
    let applicationSupport = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
    )
    return applicationSupport
        .appendingPathComponent("WAI", isDirectory: true)
        .appendingPathComponent("SecureManualData", isDirectory: true)
        .appendingPathComponent(fileName, isDirectory: false)
}
