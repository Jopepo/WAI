import Foundation
import Testing
@testable import WAI

struct ProtectedFileAttributesTests {
    @Test func sensitiveFilesUseCompleteProtectionAndSkipBackup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let recordingFileManager = ProtectionRecordingFileManager()

        let releaseURL = root.appendingPathComponent("release.cache")
        let releaseStore = ProtectedOperationalReleaseCache(
            fileURL: releaseURL,
            keyStore: ProtectedFileReleaseKeyStore(),
            fileManager: recordingFileManager
        )
        let package = try BundledOperationalReleaseProvider(bundle: .main).load()
        try releaseStore.save(
            ownerUserID: UUID(),
            manifest: package.manifest,
            payloads: package.payloads
        )

        let rosterURL = root.appendingPathComponent("roster.cache")
        let rosterStore = ProtectedRosterStore(
            fileURL: rosterURL,
            keyStore: ProtectedFileRosterKeyStore(),
            fileManager: recordingFileManager
        )
        try rosterStore.save(RosterArchive(), for: UUID())

        let manualURL = root.appendingPathComponent("manual.cache")
        let manualStore = ProtectedOwnerBoundManualDataStore<[String]>(
            fileURL: manualURL,
            keyStore: ProtectedFileManualKeyStore(),
            fileManager: recordingFileManager
        )
        try manualStore.save(["private"], for: UUID())

        for url in [releaseURL, rosterURL, manualURL] {
            try expectProtectedAndExcludedFromBackup(url)
        }
        let expectedProtectedFiles = Set(
            [releaseURL.path, rosterURL.path, manualURL.path]
        )
        #expect(
            expectedProtectedFiles.isSubset(
                of: Set(recordingFileManager.completeProtectionPaths)
            )
        )
    }

    private func expectProtectedAndExcludedFromBackup(_ url: URL) throws {
        let resourceValues = try url.resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        )
        #expect(resourceValues.isExcludedFromBackup == true)

        #if !targetEnvironment(simulator)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(
            attributes[.protectionKey] as? FileProtectionType
            == FileProtectionType.complete
        )
        #endif
    }
}

private final class ProtectionRecordingFileManager: FileManager {
    private(set) var completeProtectionPaths: [String] = []

    override func setAttributes(
        _ attributes: [FileAttributeKey: Any],
        ofItemAtPath path: String
    ) throws {
        if attributes[.protectionKey] as? FileProtectionType == .complete {
            completeProtectionPaths.append(path)
        }
        try super.setAttributes(attributes, ofItemAtPath: path)
    }
}

private final class ProtectedFileReleaseKeyStore: OperationalReleaseKeyStore {
    func loadOrCreateKeyData() throws -> Data {
        Data(repeating: 0x11, count: 32)
    }

    func deleteKey() throws { }
}

private final class ProtectedFileRosterKeyStore: RosterEncryptionKeyStoring {
    func loadOrCreateKeyData() throws -> Data {
        Data(repeating: 0x22, count: 32)
    }

    func deleteKey() throws { }
}

private final class ProtectedFileManualKeyStore:
    ManualDataEncryptionKeyStoring
{
    func loadOrCreateKeyData() throws -> Data {
        Data(repeating: 0x33, count: 32)
    }

    func deleteKey() throws { }
}
