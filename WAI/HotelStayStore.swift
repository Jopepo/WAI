import Foundation

struct HotelStay: Codable, Identifiable, Equatable {
    let id: UUID
    var sourceCalculationID: UUID?
    let stationIATA: String
    let hotelName: String
    let city: String
    let country: String
    var roomNumber: String
    let etdDate: Date
    var etdTimeText: String?
    var registeredAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        sourceCalculationID: UUID?,
        stationIATA: String,
        hotelName: String,
        city: String,
        country: String,
        roomNumber: String,
        etdDate: Date,
        etdTimeText: String? = nil,
        registeredAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.sourceCalculationID = sourceCalculationID
        self.stationIATA = stationIATA
        self.hotelName = hotelName
        self.city = city
        self.country = country
        self.roomNumber = roomNumber
        self.etdDate = etdDate
        self.etdTimeText = etdTimeText
        self.registeredAt = registeredAt
        self.updatedAt = updatedAt
    }
}

struct HotelStaySnapshot: Codable {
    let stays: [HotelStay]

    static let empty = HotelStaySnapshot(stays: [])

    var isValid: Bool {
        stays.count <= 500
        && Set(stays.map(\.id)).count == stays.count
        && stays.allSatisfy { stay in
            stay.stationIATA.utf8.count == 3
            && stay.stationIATA.utf8.allSatisfy { byte in
                (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            }
            && !stay.hotelName.isEmpty
            && stay.hotelName.count <= 256
            && !stay.city.isEmpty
            && stay.city.count <= 128
            && !stay.country.isEmpty
            && stay.country.count <= 128
            && !stay.roomNumber.isEmpty
            && stay.roomNumber.count <= 64
            && (stay.etdTimeText?.count ?? 0) <= 32
            && stay.etdDate.timeIntervalSinceReferenceDate.isFinite
            && stay.registeredAt.timeIntervalSinceReferenceDate.isFinite
            && stay.updatedAt.timeIntervalSinceReferenceDate.isFinite
        }
    }
}

protocol HotelStayPersisting: WAISensitiveOperationalDataClearing {
    var requiresOwner: Bool { get }
    func load(for ownerUserID: UUID?) throws -> HotelStaySnapshot
    func save(_ snapshot: HotelStaySnapshot, for ownerUserID: UUID?) throws
}

final class UserDefaultsHotelStayPersistence: HotelStayPersisting {
    let requiresOwner = false

    private let staysKey = "wai.hotelStays"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(for ownerUserID: UUID?) throws -> HotelStaySnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let stays = defaults.data(forKey: staysKey).flatMap {
            try? decoder.decode([HotelStay].self, from: $0)
        } ?? []
        return HotelStaySnapshot(stays: stays)
    }

    func save(
        _ snapshot: HotelStaySnapshot,
        for ownerUserID: UUID?
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(try encoder.encode(snapshot.stays), forKey: staysKey)
    }

    func clear() throws {
        defaults.removeObject(forKey: staysKey)
    }
}

final class ProtectedHotelStayPersistence: HotelStayPersisting {
    let requiresOwner = true
    private let store: ProtectedOwnerBoundManualDataStore<HotelStaySnapshot>

    init(store: ProtectedOwnerBoundManualDataStore<HotelStaySnapshot>) {
        self.store = store
    }

    static func production() throws -> ProtectedHotelStayPersistence {
        ProtectedHotelStayPersistence(
            store: ProtectedOwnerBoundManualDataStore(
                fileURL: try waiSecureManualDataURL(
                    fileName: "hotel-stays-v1.cache"
                ),
                keyStore: KeychainManualDataEncryptionKeyStore(
                    service: "com.jplabs.WAI.secure-hotel-stays"
                )
            )
        )
    }

    func load(for ownerUserID: UUID?) throws -> HotelStaySnapshot {
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
        _ snapshot: HotelStaySnapshot,
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
final class HotelStayStore: ObservableObject {
    static let shared = HotelStayStore()

    @Published private(set) var stays: [HotelStay] = []
    @Published private(set) var storageState: WAIManualDataStoreState = .idle

    private let persistence: HotelStayPersisting
    private var ownerUserID: UUID?

    init(
        persistence: HotelStayPersisting = UserDefaultsHotelStayPersistence()
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
        stays = []
        storageState = .idle
    }

    func stays(for hotel: Hotel) -> [HotelStay] {
        stays
            .filter { $0.stationIATA == hotel.iata && $0.hotelName == hotel.name }
            .sorted { $0.registeredAt > $1.registeredAt }
    }

    @discardableResult
    func upsertStay(
        for item: CalculationHistoryItem,
        hotel: Hotel,
        roomNumber: String
    ) -> Bool {
        let trimmedRoomNumber = roomNumber.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedRoomNumber.isEmpty else {
            return true
        }

        var next = stays
        if let index = next.firstIndex(where: {
            $0.sourceCalculationID == item.id
        }) {
            next[index].roomNumber = trimmedRoomNumber
            next[index].etdTimeText = item.inputTimeText
            next[index].updatedAt = Date()
        } else {
            next.insert(
                HotelStay(
                    sourceCalculationID: item.id,
                    stationIATA: hotel.iata,
                    hotelName: hotel.name,
                    city: hotel.city,
                    country: hotel.country,
                    roomNumber: trimmedRoomNumber,
                    etdDate: item.etdDate,
                    etdTimeText: item.inputTimeText
                ),
                at: 0
            )
        }
        return persist(HotelStaySnapshot(stays: next))
    }

    @discardableResult
    func removeStay(for item: CalculationHistoryItem) -> Bool {
        persist(
            HotelStaySnapshot(
                stays: stays.filter { $0.sourceCalculationID != item.id }
            )
        )
    }

    @discardableResult
    func delete(_ stay: HotelStay) -> Bool {
        persist(
            HotelStaySnapshot(
                stays: stays.filter { $0.id != stay.id }
            )
        )
    }

    @discardableResult
    func detachCalculation(_ item: CalculationHistoryItem) -> Bool {
        guard let index = stays.firstIndex(where: {
            $0.sourceCalculationID == item.id
        }) else {
            return true
        }
        var next = stays
        next[index].sourceCalculationID = nil
        next[index].updatedAt = Date()
        return persist(HotelStaySnapshot(stays: next))
    }

    private func load(for ownerUserID: UUID?) {
        do {
            stays = try persistence.load(for: ownerUserID).stays
            storageState = .ready
        } catch ProtectedManualDataStoreError.ownerMismatch {
            do {
                try persistence.clear()
                stays = []
                storageState = .ready
            } catch {
                stays = []
                storageState = .failedSecureStorage
            }
        } catch {
            stays = []
            storageState = .failedSecureStorage
        }
    }

    private func persist(_ snapshot: HotelStaySnapshot) -> Bool {
        do {
            try persistence.save(snapshot, for: ownerUserID)
            stays = snapshot.stays
            storageState = .ready
            return true
        } catch {
            storageState = .failedSecureStorage
            return false
        }
    }
}
