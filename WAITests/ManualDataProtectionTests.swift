import Foundation
import Testing
@testable import WAI

@MainActor
struct ManualDataProtectionTests {
    private let owner = UUID(
        uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    )!
    private let otherOwner = UUID(
        uuidString: "11111111-2222-3333-4444-555555555555"
    )!

    @Test func calculationHistoryIsEncryptedAndOwnerBound() throws {
        let fixture = try ManualDataFixture<CalculationHistorySnapshot>()
        let persistence = ProtectedCalculationHistoryPersistence(
            store: fixture.store
        )
        let controller = CalculationHistoryStore(persistence: persistence)
        controller.prepare(for: owner)

        let item = calculation(roomNumber: "1207")
        #expect(controller.save(item))

        let encrypted = try Data(contentsOf: fixture.fileURL)
        #expect(encrypted.range(of: Data("Accra".utf8)) == nil)
        #expect(encrypted.range(of: Data("1207".utf8)) == nil)

        let restored = CalculationHistoryStore(persistence: persistence)
        restored.prepare(for: owner)
        #expect(restored.history == [item])
        #expect(restored.lastCalculation == item)

        #expect(throws: ProtectedManualDataStoreError.ownerMismatch) {
            _ = try fixture.store.load(for: otherOwner)
        }
    }

    @Test func hotelStayHistoryIsEncryptedAndOwnerBound() throws {
        let fixture = try ManualDataFixture<HotelStaySnapshot>()
        let persistence = ProtectedHotelStayPersistence(store: fixture.store)
        let controller = HotelStayStore(persistence: persistence)
        controller.prepare(for: owner)

        let calculation = calculation(roomNumber: "1207")
        let hotel = Hotel(
            iata: "ACC",
            icao: "DGAA",
            city: "Accra",
            country: "Ghana",
            name: "TEST HOTEL",
            phone: nil,
            email: nil,
            fax: nil
        )
        #expect(
            controller.upsertStay(
                for: calculation,
                hotel: hotel,
                roomNumber: "1207"
            )
        )

        let encrypted = try Data(contentsOf: fixture.fileURL)
        #expect(encrypted.range(of: Data("TEST HOTEL".utf8)) == nil)
        #expect(encrypted.range(of: Data("1207".utf8)) == nil)

        let restored = HotelStayStore(persistence: persistence)
        restored.prepare(for: owner)
        #expect(restored.stays.count == 1)
        #expect(restored.stays.first?.roomNumber == "1207")
    }

    @Test func tamperedManualDataIsRejected() throws {
        let fixture = try ManualDataFixture<CalculationHistorySnapshot>()
        let item = calculation()
        try fixture.store.save(
            CalculationHistorySnapshot(
                history: [item],
                lastCalculation: item
            ),
            for: owner
        )

        var encrypted = try Data(contentsOf: fixture.fileURL)
        encrypted[encrypted.startIndex] ^= 0x01
        try encrypted.write(to: fixture.fileURL, options: .atomic)

        var rejected = false
        do {
            _ = try fixture.store.load(for: owner)
        } catch {
            rejected = true
        }
        #expect(rejected)
    }

    @Test func clearingManualDataDeletesFileAndKey() throws {
        let fixture = try ManualDataFixture<CalculationHistorySnapshot>()
        let item = calculation()
        try fixture.store.save(
            CalculationHistorySnapshot(
                history: [item],
                lastCalculation: item
            ),
            for: owner
        )

        try fixture.store.clear()

        #expect(!FileManager.default.fileExists(atPath: fixture.fileURL.path))
        #expect(fixture.keyStore.deleteCount == 1)
    }

    @Test func failedSecureSaveDoesNotPublishUnsavedCalculation() {
        let persistence = FailingCalculationHistoryPersistence()
        let controller = CalculationHistoryStore(persistence: persistence)
        controller.prepare(for: owner)

        #expect(!controller.save(calculation()))
        #expect(controller.history.isEmpty)
        #expect(controller.lastCalculation == nil)
        #expect(controller.storageState == .failedSecureStorage)
    }

    private func calculation(
        roomNumber: String? = nil
    ) -> CalculationHistoryItem {
        CalculationHistoryItem(
            id: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
            createdAt: Date(timeIntervalSince1970: 1_784_112_400),
            stationIATA: "ACC",
            stationCity: "Accra",
            etdDate: Date(timeIntervalSince1970: 1_784_119_600),
            inputReference: .utc,
            inputTimeText: "18:30",
            pickupTimeText: "16:15",
            wakeupTimeText: "15:15",
            roomNumber: roomNumber,
            appliedRuleLabel: "Fixed"
        )
    }
}

private final class InMemoryManualDataKeyStore:
    ManualDataEncryptionKeyStoring
{
    var keyData = Data(repeating: 0xA5, count: 32)
    private(set) var deleteCount = 0

    func loadOrCreateKeyData() throws -> Data {
        keyData
    }

    func deleteKey() throws {
        deleteCount += 1
    }
}

private struct ManualDataFixture<Value: Codable> {
    let directory: URL
    let fileURL: URL
    let keyStore: InMemoryManualDataKeyStore
    let store: ProtectedOwnerBoundManualDataStore<Value>

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        fileURL = directory.appendingPathComponent("manual.cache")
        keyStore = InMemoryManualDataKeyStore()
        store = ProtectedOwnerBoundManualDataStore(
            fileURL: fileURL,
            keyStore: keyStore
        )
    }
}

private final class FailingCalculationHistoryPersistence:
    CalculationHistoryPersisting
{
    enum Failure: Error {
        case expected
    }

    let requiresOwner = true

    func load(for ownerUserID: UUID?) throws -> CalculationHistorySnapshot {
        .empty
    }

    func save(
        _ snapshot: CalculationHistorySnapshot,
        for ownerUserID: UUID?
    ) throws {
        throw Failure.expected
    }

    func clear() throws {}
}
