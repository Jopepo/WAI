import Foundation

struct RosterHomeRoutineSettings: Codable, Equatable, Sendable {
    let baseIATA: String
    let travelMinutes: Int
    let wakeupBufferMinutes: Int

    var isValid: Bool {
        baseIATA.utf8.count == 3
        && baseIATA.utf8.allSatisfy { byte in
            (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
        }
        && (1...300).contains(travelMinutes)
        && (0...300).contains(wakeupBufferMinutes)
    }
}

struct RosterLegBriefingRecord: Codable, Equatable, Sendable, Identifiable {
    let legID: String
    let passengerLoad: String?
    let plannedFlightMinutes: Int?
    let commanderPassword: String?
    let updatedAt: Date

    var id: String {
        legID
    }

    var isEmpty: Bool {
        passengerLoad == nil
        && plannedFlightMinutes == nil
        && commanderPassword == nil
    }

    var isValid: Bool {
        !legID.isEmpty
        && legID.utf8.count <= 512
        && validOptionalText(passengerLoad, maximumBytes: 128)
        && plannedFlightMinutes.map { (1...1_440).contains($0) } != false
        && validOptionalText(commanderPassword, maximumBytes: 256)
        && updatedAt.timeIntervalSinceReferenceDate.isFinite
        && !isEmpty
    }

    private func validOptionalText(
        _ value: String?,
        maximumBytes: Int
    ) -> Bool {
        guard let value else {
            return true
        }
        return !value.isEmpty
        && value.utf8.count <= maximumBytes
        && value.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
        }
    }
}

struct RosterPersonalizationSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let homeRoutine: RosterHomeRoutineSettings?
    let briefingRecords: [RosterLegBriefingRecord]

    init(
        schemaVersion: Int = currentSchemaVersion,
        homeRoutine: RosterHomeRoutineSettings?,
        briefingRecords: [RosterLegBriefingRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.homeRoutine = homeRoutine
        self.briefingRecords = briefingRecords
    }

    var isValid: Bool {
        schemaVersion == Self.currentSchemaVersion
        && homeRoutine.map(\.isValid) != false
        && briefingRecords.count <= 500
        && briefingRecords.allSatisfy(\.isValid)
        && Set(briefingRecords.map(\.legID)).count == briefingRecords.count
    }
}

protocol RosterPersonalizationStoring: WAISensitiveOperationalDataClearing {
    func load(for ownerUserID: UUID) throws -> RosterPersonalizationSnapshot?
    func save(
        _ snapshot: RosterPersonalizationSnapshot,
        for ownerUserID: UUID
    ) throws
}

final class ProtectedRosterPersonalizationStore:
    RosterPersonalizationStoring
{
    private let store:
        ProtectedOwnerBoundManualDataStore<RosterPersonalizationSnapshot>

    init(
        store: ProtectedOwnerBoundManualDataStore<
            RosterPersonalizationSnapshot
        >
    ) {
        self.store = store
    }

    static func production() throws -> ProtectedRosterPersonalizationStore {
        ProtectedRosterPersonalizationStore(
            store: ProtectedOwnerBoundManualDataStore(
                fileURL: try waiSecureManualDataURL(
                    fileName: "roster-personalization-v1.bin"
                ),
                keyStore: KeychainManualDataEncryptionKeyStore(
                    service: "com.jplabs.WAI.roster-personalization"
                )
            )
        )
    }

    func load(
        for ownerUserID: UUID
    ) throws -> RosterPersonalizationSnapshot? {
        try store.load(for: ownerUserID)
    }

    func save(
        _ snapshot: RosterPersonalizationSnapshot,
        for ownerUserID: UUID
    ) throws {
        try store.save(snapshot, for: ownerUserID)
    }

    func clear() throws {
        try store.clear()
    }
}

enum WAIRosterPersonalizationState: Equatable, Sendable {
    case idle
    case ready
    case failedSecureStorage
}

@MainActor
final class WAIRosterPersonalizationController: ObservableObject {
    @Published private(set) var state: WAIRosterPersonalizationState = .idle
    @Published private(set) var homeRoutine: RosterHomeRoutineSettings?
    @Published private(set) var briefingRecords:
        [String: RosterLegBriefingRecord] = [:]
    @Published private(set) var saveFailed = false

    private let store: RosterPersonalizationStoring
    private let now: () -> Date
    private var ownerUserID: UUID?

    init(
        store: RosterPersonalizationStoring,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.now = now
    }

    func prepare(for ownerUserID: UUID) {
        self.ownerUserID = ownerUserID
        saveFailed = false

        do {
            let snapshot = try store.load(for: ownerUserID)
                ?? RosterPersonalizationSnapshot(
                    homeRoutine: nil,
                    briefingRecords: []
                )
            guard snapshot.isValid else {
                failSecureStorage()
                return
            }
            apply(snapshot)
            state = .ready
        } catch ProtectedManualDataStoreError.ownerMismatch {
            do {
                try store.clear()
                apply(
                    RosterPersonalizationSnapshot(
                        homeRoutine: nil,
                        briefingRecords: []
                    )
                )
                state = .ready
            } catch {
                failSecureStorage()
            }
        } catch {
            failSecureStorage()
        }
    }

    func briefing(for legID: String) -> RosterLegBriefingRecord? {
        briefingRecords[legID]
    }

    @discardableResult
    func setHomeRoutine(
        baseIATA: String,
        travelMinutes: Int,
        wakeupBufferMinutes: Int
    ) -> Bool {
        let settings = RosterHomeRoutineSettings(
            baseIATA: baseIATA
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased(),
            travelMinutes: travelMinutes,
            wakeupBufferMinutes: wakeupBufferMinutes
        )
        guard settings.isValid else {
            saveFailed = true
            return false
        }
        return save(homeRoutine: settings, records: Array(briefingRecords.values))
    }

    @discardableResult
    func setBriefing(
        for legID: String,
        passengerLoad: String,
        plannedFlightMinutes: Int?,
        commanderPassword: String
    ) -> Bool {
        let normalizedPassengerLoad = normalized(passengerLoad)
        let normalizedPassword = normalized(commanderPassword)
        var records = briefingRecords
        let record = RosterLegBriefingRecord(
            legID: legID,
            passengerLoad: normalizedPassengerLoad,
            plannedFlightMinutes: plannedFlightMinutes,
            commanderPassword: normalizedPassword,
            updatedAt: now()
        )

        if record.isEmpty {
            records.removeValue(forKey: legID)
        } else {
            guard record.isValid else {
                saveFailed = true
                return false
            }
            records[legID] = record
        }

        let limitedRecords = records.values
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(500)
        return save(
            homeRoutine: homeRoutine,
            records: Array(limitedRecords)
        )
    }

    func clearSaveFailure() {
        saveFailed = false
    }

    func reset() {
        ownerUserID = nil
        homeRoutine = nil
        briefingRecords = [:]
        saveFailed = false
        state = .idle
    }

    private func save(
        homeRoutine: RosterHomeRoutineSettings?,
        records: [RosterLegBriefingRecord]
    ) -> Bool {
        guard state == .ready, let ownerUserID else {
            saveFailed = true
            return false
        }
        let snapshot = RosterPersonalizationSnapshot(
            homeRoutine: homeRoutine,
            briefingRecords: records
        )
        guard snapshot.isValid else {
            saveFailed = true
            return false
        }

        do {
            try store.save(snapshot, for: ownerUserID)
            apply(snapshot)
            saveFailed = false
            return true
        } catch {
            saveFailed = true
            return false
        }
    }

    private func apply(_ snapshot: RosterPersonalizationSnapshot) {
        homeRoutine = snapshot.homeRoutine
        briefingRecords = Dictionary(
            uniqueKeysWithValues: snapshot.briefingRecords.map {
                ($0.legID, $0)
            }
        )
    }

    private func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func failSecureStorage() {
        homeRoutine = nil
        briefingRecords = [:]
        saveFailed = false
        state = .failedSecureStorage
    }
}

struct RosterHomeRoutine: Equatable, Sendable {
    let dutyID: String
    let stationIATA: String
    let timeZoneIdentifier: String
    let report: Date
    let leaveHome: Date
    let wakeup: Date
    let travelMinutes: Int
}

struct RosterHomeRoutineBuilder {
    static func routine(
        for duty: RosterDuty,
        settings: RosterHomeRoutineSettings?
    ) -> RosterHomeRoutine? {
        guard let settings,
              settings.isValid,
              duty.kind == .flight,
              duty.legs.first?.originIATA == settings.baseIATA else {
            return nil
        }

        let leaveHome = duty.start.addingTimeInterval(
            -Double(settings.travelMinutes * 60)
        )
        let wakeup = leaveHome.addingTimeInterval(
            -Double(settings.wakeupBufferMinutes * 60)
        )
        return RosterHomeRoutine(
            dutyID: duty.id,
            stationIATA: settings.baseIATA,
            timeZoneIdentifier: duty.startTimeZoneIdentifier,
            report: duty.start,
            leaveHome: leaveHome,
            wakeup: wakeup,
            travelMinutes: settings.travelMinutes
        )
    }
}
