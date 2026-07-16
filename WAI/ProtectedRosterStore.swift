import CryptoKit
import Foundation
import Security

protocol RosterEncryptionKeyStoring {
    func loadOrCreateKeyData() throws -> Data
    func deleteKey() throws
}

enum RosterEncryptionKeyStoreError: Error, Equatable {
    case invalidKeyLength
    case randomGeneration(OSStatus)
}

final class KeychainRosterEncryptionKeyStore: RosterEncryptionKeyStoring {
    private let account = "encryption-key-v1"
    private let keyByteCount = 32
    private let keychain = WAIKeychainDataStore(
        service: "com.jplabs.WAI.roster-cache"
    )

    func loadOrCreateKeyData() throws -> Data {
        if let data = try keychain.load(account: account) {
            guard data.count == keyByteCount else {
                throw RosterEncryptionKeyStoreError.invalidKeyLength
            }
            return data
        }

        var bytes = [UInt8](repeating: 0, count: keyByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw RosterEncryptionKeyStoreError.randomGeneration(status)
        }
        let data = Data(bytes)
        try keychain.save(data, account: account)
        return data
    }

    func deleteKey() throws {
        try keychain.clear(account: account)
    }
}

protocol RosterArchiveStoring {
    func load(for ownerUserID: UUID) throws -> RosterArchive?
    func save(_ archive: RosterArchive, for ownerUserID: UUID) throws
    func clear() throws
}

enum ProtectedRosterStoreError: Error, Equatable {
    case invalidKeyLength
    case missingEncryptedRepresentation
    case ownerMismatch
    case invalidEnvelope
    case fileTooLarge
}

private struct ProtectedRosterEnvelope: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let ownerUserID: UUID
    let archive: RosterArchive
}

final class ProtectedRosterStore:
    RosterArchiveStoring,
    WAISensitiveOperationalDataClearing
{
    private let maximumFileBytes = 8 * 1_024 * 1_024
    private let fileURL: URL
    private let keyStore: RosterEncryptionKeyStoring
    private let fileManager: FileManager

    init(
        fileURL: URL,
        keyStore: RosterEncryptionKeyStoring,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.keyStore = keyStore
        self.fileManager = fileManager
    }

    static func production() throws -> ProtectedRosterStore {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let fileURL = applicationSupport
            .appendingPathComponent("WAI", isDirectory: true)
            .appendingPathComponent("SecureRoster", isDirectory: true)
            .appendingPathComponent("roster-v1.cache", isDirectory: false)
        return ProtectedRosterStore(
            fileURL: fileURL,
            keyStore: KeychainRosterEncryptionKeyStore()
        )
    }

    func load(for ownerUserID: UUID) throws -> RosterArchive? {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        if let size = attributes[.size] as? NSNumber,
           size.intValue > maximumFileBytes {
            throw ProtectedRosterStoreError.fileTooLarge
        }

        let encrypted = try Data(contentsOf: fileURL)
        let sealed = try AES.GCM.SealedBox(combined: encrypted)
        let decrypted = try AES.GCM.open(sealed, using: encryptionKey())
        let envelope = try JSONDecoder().decode(
            ProtectedRosterEnvelope.self,
            from: decrypted
        )
        guard envelope.schemaVersion
                == ProtectedRosterEnvelope.currentSchemaVersion,
              envelope.archive.isValid else {
            throw ProtectedRosterStoreError.invalidEnvelope
        }
        guard envelope.ownerUserID == ownerUserID else {
            throw ProtectedRosterStoreError.ownerMismatch
        }
        return envelope.archive
    }

    func save(_ archive: RosterArchive, for ownerUserID: UUID) throws {
        guard archive.isValid else {
            throw ProtectedRosterStoreError.invalidEnvelope
        }
        let envelope = ProtectedRosterEnvelope(
            schemaVersion: ProtectedRosterEnvelope.currentSchemaVersion,
            ownerUserID: ownerUserID,
            archive: archive
        )
        let encoded = try JSONEncoder().encode(envelope)
        let sealed = try AES.GCM.seal(encoded, using: encryptionKey())
        guard let combined = sealed.combined else {
            throw ProtectedRosterStoreError.missingEncryptedRepresentation
        }
        guard combined.count <= maximumFileBytes else {
            throw ProtectedRosterStoreError.fileTooLarge
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
            throw ProtectedRosterStoreError.invalidKeyLength
        }
        return SymmetricKey(data: data)
    }
}

final class WAISensitiveDataStoreGroup: WAISensitiveOperationalDataClearing {
    private let stores: [WAISensitiveOperationalDataClearing]

    init(_ stores: [WAISensitiveOperationalDataClearing]) {
        self.stores = stores
    }

    func clear() throws {
        var firstError: Error?
        for store in stores {
            do {
                try store.clear()
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }
        if let firstError {
            throw firstError
        }
    }
}
