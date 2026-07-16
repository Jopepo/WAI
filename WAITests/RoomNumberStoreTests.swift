import Foundation
import Testing
@testable import WAI

struct RoomNumberStoreTests {
    private let ownerID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let otherOwnerID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let now = Date(timeIntervalSince1970: 1_784_112_400)

    @Test func keychainStoreRoundTripsValidatedRecords() throws {
        let dataStore = StubRoomSecureDataStore()
        let store = KeychainRosterRoomNumberStore(
            secureDataStore: dataStore
        )
        let records = [record(stayID: "stay-1", room: "1207")]

        try store.save(records, for: ownerID)
        let loaded = try store.load(for: ownerID)

        #expect(loaded == records)
        #expect(dataStore.savedAccounts == ["room-numbers-v1"])
    }

    @Test func keychainStoreRejectsAnotherOwner() throws {
        let dataStore = StubRoomSecureDataStore()
        let store = KeychainRosterRoomNumberStore(
            secureDataStore: dataStore
        )
        try store.save([record(stayID: "stay-1", room: "1207")], for: ownerID)

        #expect(throws: ProtectedRoomNumberStoreError.ownerMismatch) {
            _ = try store.load(for: otherOwnerID)
        }
    }

    @Test func invalidRoomNumberIsRejectedBeforeKeychainWrite() {
        let dataStore = StubRoomSecureDataStore()
        let store = KeychainRosterRoomNumberStore(
            secureDataStore: dataStore
        )
        let invalid = RosterRoomNumberRecord(
            stayID: "stay-1",
            roomNumber: String(repeating: "1", count: 65),
            updatedAt: now
        )

        #expect(throws: ProtectedRoomNumberStoreError.invalidEnvelope) {
            try store.save([invalid], for: ownerID)
        }
        #expect(dataStore.savedAccounts.isEmpty)
    }

    @Test func clearRemovesTheDedicatedKeychainValue() throws {
        let dataStore = StubRoomSecureDataStore()
        let store = KeychainRosterRoomNumberStore(
            secureDataStore: dataStore
        )
        try store.save([record(stayID: "stay-1", room: "1207")], for: ownerID)

        try store.clear()

        #expect(try store.load(for: ownerID).isEmpty)
        #expect(dataStore.clearedAccounts == ["room-numbers-v1"])
    }

    private func record(stayID: String, room: String) -> RosterRoomNumberRecord {
        RosterRoomNumberRecord(
            stayID: stayID,
            roomNumber: room,
            updatedAt: now
        )
    }
}

@MainActor
struct RoomNumberControllerTests {
    private let ownerID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let now = Date(timeIntervalSince1970: 1_784_112_400)

    @Test func savePublishesOnlyAfterProtectedStoreSucceeds() {
        let store = StubRosterRoomNumberStore()
        let controller = makeController(store: store)
        controller.prepare(for: ownerID)

        let saved = controller.setRoomNumber(" 1207 ", for: "stay-1")

        #expect(saved)
        #expect(controller.roomNumber(for: "stay-1") == "1207")
        #expect(store.records.first?.roomNumber == "1207")
        #expect(store.savedOwner == ownerID)
    }

    @Test func emptyRoomNumberRemovesExistingRecord() {
        let store = StubRosterRoomNumberStore(
            records: [
                RosterRoomNumberRecord(
                    stayID: "stay-1",
                    roomNumber: "1207",
                    updatedAt: now
                )
            ]
        )
        let controller = makeController(store: store)
        controller.prepare(for: ownerID)

        let saved = controller.setRoomNumber("   ", for: "stay-1")

        #expect(saved)
        #expect(controller.roomNumber(for: "stay-1") == nil)
        #expect(store.records.isEmpty)
    }

    @Test func failedSaveKeepsPreviouslyPublishedRoom() {
        let existing = RosterRoomNumberRecord(
            stayID: "stay-1",
            roomNumber: "1207",
            updatedAt: now
        )
        let store = StubRosterRoomNumberStore(records: [existing])
        let controller = makeController(store: store)
        controller.prepare(for: ownerID)
        store.saveError = StubRosterRoomNumberStore.Failure.expected

        let saved = controller.setRoomNumber("1402", for: "stay-1")

        #expect(!saved)
        #expect(controller.roomNumber(for: "stay-1") == "1207")
        #expect(controller.saveFailed)
    }

    @Test func anotherOwnersDataIsClearedBeforeUse() {
        let store = StubRosterRoomNumberStore()
        store.loadError = ProtectedRoomNumberStoreError.ownerMismatch
        let controller = makeController(store: store)

        controller.prepare(for: ownerID)

        #expect(store.clearCount == 1)
        #expect(controller.state == .ready)
        #expect(controller.roomNumbers.isEmpty)
    }

    @Test func resetDropsRoomNumbersFromMemory() {
        let store = StubRosterRoomNumberStore(
            records: [
                RosterRoomNumberRecord(
                    stayID: "stay-1",
                    roomNumber: "1207",
                    updatedAt: now
                )
            ]
        )
        let controller = makeController(store: store)
        controller.prepare(for: ownerID)

        controller.reset()

        #expect(controller.state == .idle)
        #expect(controller.roomNumbers.isEmpty)
    }

    private func makeController(
        store: StubRosterRoomNumberStore
    ) -> WAIRoomNumberController {
        WAIRoomNumberController(store: store, now: { now })
    }
}

private final class StubRoomSecureDataStore: RoomNumberSecureDataStoring {
    private var values: [String: Data] = [:]
    private(set) var savedAccounts: [String] = []
    private(set) var clearedAccounts: [String] = []

    func load(account: String) throws -> Data? {
        values[account]
    }

    func save(_ data: Data, account: String) throws {
        values[account] = data
        savedAccounts.append(account)
    }

    func clear(account: String) throws {
        values[account] = nil
        clearedAccounts.append(account)
    }
}

private final class StubRosterRoomNumberStore: RosterRoomNumberStoring {
    enum Failure: Error {
        case expected
    }

    var records: [RosterRoomNumberRecord]
    var loadError: Error?
    var saveError: Error?
    var clearError: Error?
    private(set) var savedOwner: UUID?
    private(set) var clearCount = 0

    init(records: [RosterRoomNumberRecord] = []) {
        self.records = records
    }

    func load(for ownerUserID: UUID) throws -> [RosterRoomNumberRecord] {
        if let loadError {
            throw loadError
        }
        return records
    }

    func save(
        _ records: [RosterRoomNumberRecord],
        for ownerUserID: UUID
    ) throws {
        if let saveError {
            throw saveError
        }
        self.records = records
        savedOwner = ownerUserID
    }

    func clear() throws {
        clearCount += 1
        if let clearError {
            throw clearError
        }
        records = []
    }
}
