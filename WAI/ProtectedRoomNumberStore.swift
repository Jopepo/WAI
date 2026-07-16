import Foundation

struct RosterRoomNumberRecord: Codable, Equatable, Sendable, Identifiable {
    let stayID: String
    let roomNumber: String
    let updatedAt: Date

    var id: String {
        stayID
    }

    var isValid: Bool {
        !stayID.isEmpty
        && stayID.utf8.count <= 512
        && !roomNumber.isEmpty
        && roomNumber.count <= 64
        && roomNumber.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
        }
    }
}

private struct RosterRoomNumberEnvelope: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let ownerUserID: UUID
    let records: [RosterRoomNumberRecord]

    var isValid: Bool {
        schemaVersion == Self.currentSchemaVersion
        && records.count <= 100
        && records.allSatisfy(\.isValid)
        && Set(records.map(\.stayID)).count == records.count
    }
}

protocol RoomNumberSecureDataStoring {
    func load(account: String) throws -> Data?
    func save(_ data: Data, account: String) throws
    func clear(account: String) throws
}

extension WAIKeychainDataStore: RoomNumberSecureDataStoring {}

protocol RosterRoomNumberStoring: WAISensitiveOperationalDataClearing {
    func load(for ownerUserID: UUID) throws -> [RosterRoomNumberRecord]
    func save(
        _ records: [RosterRoomNumberRecord],
        for ownerUserID: UUID
    ) throws
}

enum ProtectedRoomNumberStoreError: Error, Equatable {
    case ownerMismatch
    case invalidEnvelope
    case dataTooLarge
}

final class KeychainRosterRoomNumberStore: RosterRoomNumberStoring {
    private let account = "room-numbers-v1"
    private let maximumEncodedBytes = 32 * 1_024
    private let secureDataStore: RoomNumberSecureDataStoring

    init(
        secureDataStore: RoomNumberSecureDataStoring = WAIKeychainDataStore(
            service: "com.jplabs.WAI.roster-room-numbers"
        )
    ) {
        self.secureDataStore = secureDataStore
    }

    func load(for ownerUserID: UUID) throws -> [RosterRoomNumberRecord] {
        guard let data = try secureDataStore.load(account: account) else {
            return []
        }
        guard data.count <= maximumEncodedBytes else {
            throw ProtectedRoomNumberStoreError.dataTooLarge
        }
        let envelope = try JSONDecoder().decode(
            RosterRoomNumberEnvelope.self,
            from: data
        )
        guard envelope.isValid else {
            throw ProtectedRoomNumberStoreError.invalidEnvelope
        }
        guard envelope.ownerUserID == ownerUserID else {
            throw ProtectedRoomNumberStoreError.ownerMismatch
        }
        return envelope.records
    }

    func save(
        _ records: [RosterRoomNumberRecord],
        for ownerUserID: UUID
    ) throws {
        let envelope = RosterRoomNumberEnvelope(
            schemaVersion: RosterRoomNumberEnvelope.currentSchemaVersion,
            ownerUserID: ownerUserID,
            records: records
        )
        guard envelope.isValid else {
            throw ProtectedRoomNumberStoreError.invalidEnvelope
        }
        let data = try JSONEncoder().encode(envelope)
        guard data.count <= maximumEncodedBytes else {
            throw ProtectedRoomNumberStoreError.dataTooLarge
        }
        try secureDataStore.save(data, account: account)
    }

    func clear() throws {
        try secureDataStore.clear(account: account)
    }
}

enum WAIRoomNumberState: Equatable, Sendable {
    case idle
    case ready
    case failedSecureStorage
}

@MainActor
final class WAIRoomNumberController: ObservableObject {
    @Published private(set) var state: WAIRoomNumberState = .idle
    @Published private(set) var roomNumbers: [String: String] = [:]
    @Published private(set) var saveFailed = false

    private let store: RosterRoomNumberStoring
    private let now: () -> Date
    private var ownerUserID: UUID?
    private var records: [RosterRoomNumberRecord] = []

    init(
        store: RosterRoomNumberStoring,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.now = now
    }

    func prepare(for ownerUserID: UUID) {
        self.ownerUserID = ownerUserID
        saveFailed = false

        do {
            let loaded = try store.load(for: ownerUserID)
            apply(loaded)
            state = .ready
        } catch ProtectedRoomNumberStoreError.ownerMismatch {
            do {
                try store.clear()
                apply([])
                state = .ready
            } catch {
                failSecureStorage()
            }
        } catch {
            failSecureStorage()
        }
    }

    func roomNumber(for stayID: String) -> String? {
        roomNumbers[stayID]
    }

    @discardableResult
    func setRoomNumber(_ value: String, for stayID: String) -> Bool {
        guard state == .ready,
              let ownerUserID,
              !stayID.isEmpty else {
            saveFailed = true
            return false
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 64,
              trimmed.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
              }) else {
            saveFailed = true
            return false
        }

        var updated = records.filter { $0.stayID != stayID }
        if !trimmed.isEmpty {
            updated.append(
                RosterRoomNumberRecord(
                    stayID: stayID,
                    roomNumber: trimmed,
                    updatedAt: now()
                )
            )
        }
        updated.sort { $0.updatedAt > $1.updatedAt }
        if updated.count > 100 {
            updated = Array(updated.prefix(100))
        }

        do {
            try store.save(updated, for: ownerUserID)
            apply(updated)
            saveFailed = false
            return true
        } catch {
            saveFailed = true
            return false
        }
    }

    func clearSaveFailure() {
        saveFailed = false
    }

    func reset() {
        ownerUserID = nil
        records = []
        roomNumbers = [:]
        saveFailed = false
        state = .idle
    }

    private func apply(_ records: [RosterRoomNumberRecord]) {
        self.records = records
        roomNumbers = Dictionary(
            uniqueKeysWithValues: records.map {
                ($0.stayID, $0.roomNumber)
            }
        )
    }

    private func failSecureStorage() {
        records = []
        roomNumbers = [:]
        state = .failedSecureStorage
    }
}
