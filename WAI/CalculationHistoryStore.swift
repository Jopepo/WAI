import Foundation

struct CalculationHistorySnapshot: Codable {
    let history: [CalculationHistoryItem]
    let lastCalculation: CalculationHistoryItem?

    static let empty = CalculationHistorySnapshot(
        history: [],
        lastCalculation: nil
    )

    var isValid: Bool {
        guard history.count <= 25,
              Set(history.map(\.id)).count == history.count,
              history.allSatisfy(Self.isValid) else {
            return false
        }
        guard let lastCalculation else {
            return true
        }
        return Self.isValid(lastCalculation)
        && history.contains { $0.id == lastCalculation.id }
    }

    private static func isValid(_ item: CalculationHistoryItem) -> Bool {
        item.stationIATA.utf8.count == 3
        && item.stationIATA.utf8.allSatisfy { byte in
            (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
        }
        && !item.stationCity.isEmpty
        && item.stationCity.count <= 128
        && !item.inputTimeText.isEmpty
        && item.inputTimeText.count <= 32
        && !item.pickupTimeText.isEmpty
        && item.pickupTimeText.count <= 128
        && !item.wakeupTimeText.isEmpty
        && item.wakeupTimeText.count <= 128
        && (item.roomNumber?.count ?? 0) <= 64
        && (item.appliedRuleLabel?.count ?? 0) <= 256
        && item.createdAt.timeIntervalSinceReferenceDate.isFinite
        && item.etdDate.timeIntervalSinceReferenceDate.isFinite
    }
}

protocol CalculationHistoryPersisting:
    WAISensitiveOperationalDataClearing
{
    var requiresOwner: Bool { get }
    func load(for ownerUserID: UUID?) throws -> CalculationHistorySnapshot
    func save(
        _ snapshot: CalculationHistorySnapshot,
        for ownerUserID: UUID?
    ) throws
}

final class UserDefaultsCalculationHistoryPersistence:
    CalculationHistoryPersisting
{
    let requiresOwner = false

    private let historyKey = "wai.calculationHistory"
    private let lastCalculationKey = "wai.lastCalculation"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(for ownerUserID: UUID?) throws -> CalculationHistorySnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let last = defaults.data(forKey: lastCalculationKey).flatMap {
            try? decoder.decode(CalculationHistoryItem.self, from: $0)
        }
        let history = defaults.data(forKey: historyKey).flatMap {
            try? decoder.decode([CalculationHistoryItem].self, from: $0)
        } ?? []
        return CalculationHistorySnapshot(
            history: history,
            lastCalculation: last
        )
    }

    func save(
        _ snapshot: CalculationHistorySnapshot,
        for ownerUserID: UUID?
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        if let last = snapshot.lastCalculation {
            defaults.set(
                try encoder.encode(last),
                forKey: lastCalculationKey
            )
        } else {
            defaults.removeObject(forKey: lastCalculationKey)
        }
        defaults.set(
            try encoder.encode(snapshot.history),
            forKey: historyKey
        )
    }

    func clear() throws {
        defaults.removeObject(forKey: historyKey)
        defaults.removeObject(forKey: lastCalculationKey)
    }
}

final class ProtectedCalculationHistoryPersistence:
    CalculationHistoryPersisting
{
    let requiresOwner = true
    private let store: ProtectedOwnerBoundManualDataStore<
        CalculationHistorySnapshot
    >

    init(
        store: ProtectedOwnerBoundManualDataStore<CalculationHistorySnapshot>
    ) {
        self.store = store
    }

    static func production() throws -> ProtectedCalculationHistoryPersistence {
        ProtectedCalculationHistoryPersistence(
            store: ProtectedOwnerBoundManualDataStore(
                fileURL: try waiSecureManualDataURL(
                    fileName: "calculation-history-v1.cache"
                ),
                keyStore: KeychainManualDataEncryptionKeyStore(
                    service: "com.jplabs.WAI.secure-calculation-history"
                )
            )
        )
    }

    func load(for ownerUserID: UUID?) throws -> CalculationHistorySnapshot {
        guard let ownerUserID else {
            throw ProtectedManualDataStoreError.ownerMismatch
        }
        let snapshot = try store.load(for: ownerUserID) ?? .empty
        guard snapshot.isValid else {
            throw ProtectedManualDataStoreError.invalidEnvelope
        }
        return snapshot
    }

    func save(
        _ snapshot: CalculationHistorySnapshot,
        for ownerUserID: UUID?
    ) throws {
        guard let ownerUserID else {
            throw ProtectedManualDataStoreError.ownerMismatch
        }
        guard snapshot.isValid else {
            throw ProtectedManualDataStoreError.invalidEnvelope
        }
        try store.save(snapshot, for: ownerUserID)
    }

    func clear() throws {
        try store.clear()
    }
}

@MainActor
final class CalculationHistoryStore: ObservableObject {
    @Published private(set) var history: [CalculationHistoryItem] = []
    @Published private(set) var lastCalculation: CalculationHistoryItem?
    @Published private(set) var storageState: WAIManualDataStoreState = .idle

    private let maxHistoryItems = 25
    private let persistence: CalculationHistoryPersisting
    private var ownerUserID: UUID?

    init(
        persistence: CalculationHistoryPersisting =
            UserDefaultsCalculationHistoryPersistence()
    ) {
        self.persistence = persistence
        if !persistence.requiresOwner {
            load(for: nil)
        }
    }

    func prepare(for ownerUserID: UUID) {
        self.ownerUserID = ownerUserID
        load(for: ownerUserID)
    }

    func resetProtectedMemory() {
        guard persistence.requiresOwner else {
            return
        }
        ownerUserID = nil
        apply(.empty)
        storageState = .idle
    }

    @discardableResult
    func save(_ item: CalculationHistoryItem) -> Bool {
        var nextHistory = history
        nextHistory.removeAll { $0.id == item.id }
        nextHistory.insert(item, at: 0)
        if nextHistory.count > maxHistoryItems {
            nextHistory = Array(nextHistory.prefix(maxHistoryItems))
        }
        return persist(
            CalculationHistorySnapshot(
                history: nextHistory,
                lastCalculation: item
            )
        )
    }

    @discardableResult
    func clearHistory() -> Bool {
        persist(.empty)
    }

    @discardableResult
    func updateRoomNumber(
        for item: CalculationHistoryItem,
        roomNumber: String?
    ) -> CalculationHistoryItem? {
        guard let index = history.firstIndex(where: { $0.id == item.id }) else {
            return nil
        }

        var nextHistory = history
        nextHistory[index].roomNumber = roomNumber
        let nextLast = lastCalculation?.id == item.id
            ? nextHistory[index]
            : lastCalculation
        guard persist(
            CalculationHistorySnapshot(
                history: nextHistory,
                lastCalculation: nextLast
            )
        ) else {
            return nil
        }
        return nextHistory[index]
    }

    @discardableResult
    func delete(_ item: CalculationHistoryItem) -> Bool {
        let nextHistory = history.filter { $0.id != item.id }
        let nextLast = lastCalculation?.id == item.id
            ? nextHistory.first
            : lastCalculation
        return persist(
            CalculationHistorySnapshot(
                history: nextHistory,
                lastCalculation: nextLast
            )
        )
    }

    private func load(for ownerUserID: UUID?) {
        do {
            apply(try persistence.load(for: ownerUserID))
            storageState = .ready
        } catch ProtectedManualDataStoreError.ownerMismatch {
            do {
                try persistence.clear()
                apply(.empty)
                storageState = .ready
            } catch {
                apply(.empty)
                storageState = .failedSecureStorage
            }
        } catch {
            apply(.empty)
            storageState = .failedSecureStorage
        }
    }

    private func persist(_ snapshot: CalculationHistorySnapshot) -> Bool {
        do {
            try persistence.save(snapshot, for: ownerUserID)
            apply(snapshot)
            storageState = .ready
            return true
        } catch {
            storageState = .failedSecureStorage
            return false
        }
    }

    private func apply(_ snapshot: CalculationHistorySnapshot) {
        history = snapshot.history
        lastCalculation = snapshot.lastCalculation
    }
}
