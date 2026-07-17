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

struct RosterHomeRoutineOverrideRecord:
    Codable, Equatable, Sendable, Identifiable
{
    let dutyID: String
    let pickupLeadMinutes: Int
    let wakeupLeadMinutes: Int
    let updatedAt: Date

    var id: String {
        dutyID
    }

    var isValid: Bool {
        !dutyID.isEmpty
        && dutyID.utf8.count <= 256
        && (1...1_440).contains(pickupLeadMinutes)
        && (pickupLeadMinutes...1_440).contains(wakeupLeadMinutes)
        && updatedAt.timeIntervalSinceReferenceDate.isFinite
    }
}

struct RosterStayRoutineOverrideRecord:
    Codable, Equatable, Sendable, Identifiable
{
    let stayID: String
    let pickupLeadMinutes: Int
    let wakeupLeadMinutes: Int
    let updatedAt: Date

    var id: String { stayID }

    var isValid: Bool {
        !stayID.isEmpty
        && stayID.utf8.count <= 512
        && (1...1_440).contains(pickupLeadMinutes)
        && (pickupLeadMinutes...1_440).contains(wakeupLeadMinutes)
        && updatedAt.timeIntervalSinceReferenceDate.isFinite
    }
}

struct RosterPersonalizationSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let homeRoutine: RosterHomeRoutineSettings?
    let briefingRecords: [RosterLegBriefingRecord]
    let homeRoutineOverrides: [RosterHomeRoutineOverrideRecord]
    let stayRoutineOverrides: [RosterStayRoutineOverrideRecord]

    init(
        schemaVersion: Int = currentSchemaVersion,
        homeRoutine: RosterHomeRoutineSettings?,
        briefingRecords: [RosterLegBriefingRecord],
        homeRoutineOverrides: [RosterHomeRoutineOverrideRecord] = [],
        stayRoutineOverrides: [RosterStayRoutineOverrideRecord] = []
    ) {
        self.schemaVersion = schemaVersion
        self.homeRoutine = homeRoutine
        self.briefingRecords = briefingRecords
        self.homeRoutineOverrides = homeRoutineOverrides
        self.stayRoutineOverrides = stayRoutineOverrides
    }

    var isValid: Bool {
        schemaVersion == Self.currentSchemaVersion
        && homeRoutine.map(\.isValid) != false
        && briefingRecords.count <= 500
        && briefingRecords.allSatisfy(\.isValid)
        && Set(briefingRecords.map(\.legID)).count == briefingRecords.count
        && homeRoutineOverrides.count <= 500
        && homeRoutineOverrides.allSatisfy(\.isValid)
        && Set(homeRoutineOverrides.map(\.dutyID)).count
            == homeRoutineOverrides.count
        && stayRoutineOverrides.count <= 500
        && stayRoutineOverrides.allSatisfy(\.isValid)
        && Set(stayRoutineOverrides.map(\.stayID)).count
            == stayRoutineOverrides.count
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case homeRoutine
        case briefingRecords
        case homeRoutineOverrides
        case stayRoutineOverrides
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        homeRoutine = try container.decodeIfPresent(
            RosterHomeRoutineSettings.self,
            forKey: .homeRoutine
        )
        briefingRecords = try container.decode(
            [RosterLegBriefingRecord].self,
            forKey: .briefingRecords
        )
        homeRoutineOverrides = try container.decodeIfPresent(
            [RosterHomeRoutineOverrideRecord].self,
            forKey: .homeRoutineOverrides
        ) ?? []
        stayRoutineOverrides = try container.decodeIfPresent(
            [RosterStayRoutineOverrideRecord].self,
            forKey: .stayRoutineOverrides
        ) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(homeRoutine, forKey: .homeRoutine)
        try container.encode(briefingRecords, forKey: .briefingRecords)
        try container.encode(
            homeRoutineOverrides,
            forKey: .homeRoutineOverrides
        )
        try container.encode(
            stayRoutineOverrides,
            forKey: .stayRoutineOverrides
        )
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
    @Published private(set) var homeRoutineOverrides:
        [String: RosterHomeRoutineOverrideRecord] = [:]
    @Published private(set) var stayRoutineOverrides:
        [String: RosterStayRoutineOverrideRecord] = [:]
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
                    briefingRecords: [],
                    homeRoutineOverrides: []
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
                        briefingRecords: [],
                        homeRoutineOverrides: []
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

    func homeRoutineOverride(
        for dutyID: String
    ) -> RosterHomeRoutineOverrideRecord? {
        homeRoutineOverrides[dutyID]
    }

    func stayRoutineOverride(
        for stayID: String
    ) -> RosterStayRoutineOverrideRecord? {
        stayRoutineOverrides[stayID]
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
        return save(
            homeRoutine: settings,
            records: Array(briefingRecords.values),
            overrides: Array(homeRoutineOverrides.values),
            stayOverrides: Array(stayRoutineOverrides.values)
        )
    }

    @discardableResult
    func setHomeRoutineOverride(
        for dutyID: String,
        report: Date,
        wakeup: Date,
        leaveHome: Date
    ) -> Bool {
        guard report.timeIntervalSinceReferenceDate.isFinite,
              wakeup.timeIntervalSinceReferenceDate.isFinite,
              leaveHome.timeIntervalSinceReferenceDate.isFinite,
              wakeup <= leaveHome,
              leaveHome < report else {
            saveFailed = true
            return false
        }
        let pickupLeadMinutes = minutes(from: leaveHome, to: report)
        let wakeupLeadMinutes = minutes(from: wakeup, to: report)
        let record = RosterHomeRoutineOverrideRecord(
            dutyID: dutyID,
            pickupLeadMinutes: pickupLeadMinutes,
            wakeupLeadMinutes: wakeupLeadMinutes,
            updatedAt: now()
        )
        guard record.isValid else {
            saveFailed = true
            return false
        }

        var overrides = homeRoutineOverrides
        overrides[dutyID] = record
        let limitedOverrides = overrides.values
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(500)
        return save(
            homeRoutine: homeRoutine,
            records: Array(briefingRecords.values),
            overrides: Array(limitedOverrides),
            stayOverrides: Array(stayRoutineOverrides.values)
        )
    }

    @discardableResult
    func clearHomeRoutineOverride(for dutyID: String) -> Bool {
        var overrides = homeRoutineOverrides
        overrides.removeValue(forKey: dutyID)
        return save(
            homeRoutine: homeRoutine,
            records: Array(briefingRecords.values),
            overrides: Array(overrides.values),
            stayOverrides: Array(stayRoutineOverrides.values)
        )
    }

    @discardableResult
    func setStayRoutineOverride(
        for stayID: String,
        report: Date,
        wakeup: Date,
        pickup: Date
    ) -> Bool {
        guard report.timeIntervalSinceReferenceDate.isFinite,
              wakeup.timeIntervalSinceReferenceDate.isFinite,
              pickup.timeIntervalSinceReferenceDate.isFinite,
              wakeup <= pickup,
              pickup < report else {
            saveFailed = true
            return false
        }
        let record = RosterStayRoutineOverrideRecord(
            stayID: stayID,
            pickupLeadMinutes: minutes(from: pickup, to: report),
            wakeupLeadMinutes: minutes(from: wakeup, to: report),
            updatedAt: now()
        )
        guard record.isValid else {
            saveFailed = true
            return false
        }

        var overrides = stayRoutineOverrides
        overrides[stayID] = record
        let limitedOverrides = overrides.values
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(500)
        return save(
            homeRoutine: homeRoutine,
            records: Array(briefingRecords.values),
            overrides: Array(homeRoutineOverrides.values),
            stayOverrides: Array(limitedOverrides)
        )
    }

    @discardableResult
    func clearStayRoutineOverride(for stayID: String) -> Bool {
        var overrides = stayRoutineOverrides
        overrides.removeValue(forKey: stayID)
        return save(
            homeRoutine: homeRoutine,
            records: Array(briefingRecords.values),
            overrides: Array(homeRoutineOverrides.values),
            stayOverrides: Array(overrides.values)
        )
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
            records: Array(limitedRecords),
            overrides: Array(homeRoutineOverrides.values),
            stayOverrides: Array(stayRoutineOverrides.values)
        )
    }

    func clearSaveFailure() {
        saveFailed = false
    }

    func reset() {
        ownerUserID = nil
        homeRoutine = nil
        briefingRecords = [:]
        homeRoutineOverrides = [:]
        stayRoutineOverrides = [:]
        saveFailed = false
        state = .idle
    }

    private func save(
        homeRoutine: RosterHomeRoutineSettings?,
        records: [RosterLegBriefingRecord],
        overrides: [RosterHomeRoutineOverrideRecord],
        stayOverrides: [RosterStayRoutineOverrideRecord]
    ) -> Bool {
        guard state == .ready, let ownerUserID else {
            saveFailed = true
            return false
        }
        let snapshot = RosterPersonalizationSnapshot(
            homeRoutine: homeRoutine,
            briefingRecords: records,
            homeRoutineOverrides: overrides,
            stayRoutineOverrides: stayOverrides
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
        homeRoutineOverrides = Dictionary(
            uniqueKeysWithValues: snapshot.homeRoutineOverrides.map {
                ($0.dutyID, $0)
            }
        )
        stayRoutineOverrides = Dictionary(
            uniqueKeysWithValues: snapshot.stayRoutineOverrides.map {
                ($0.stayID, $0)
            }
        )
    }

    private func minutes(from start: Date, to end: Date) -> Int {
        Int((end.timeIntervalSince(start) / 60).rounded())
    }

    private func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func failSecureStorage() {
        homeRoutine = nil
        briefingRecords = [:]
        homeRoutineOverrides = [:]
        stayRoutineOverrides = [:]
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
    let usesDutyOverride: Bool
}

struct RosterHomeRoutineBuilder {
    static func routine(
        for duty: RosterDuty,
        settings: RosterHomeRoutineSettings?,
        override: RosterHomeRoutineOverrideRecord? = nil
    ) -> RosterHomeRoutine? {
        guard let settings,
              settings.isValid,
              duty.kind == .flight,
              duty.legs.first?.originIATA == settings.baseIATA else {
            return nil
        }

        let validOverride = override.flatMap {
            $0.dutyID == duty.id && $0.isValid ? $0 : nil
        }
        let pickupLeadMinutes = validOverride?.pickupLeadMinutes
            ?? settings.travelMinutes
        let wakeupLeadMinutes = validOverride?.wakeupLeadMinutes
            ?? settings.travelMinutes + settings.wakeupBufferMinutes
        let leaveHome = duty.start.addingTimeInterval(
            -Double(pickupLeadMinutes * 60)
        )
        let wakeup = duty.start.addingTimeInterval(
            -Double(wakeupLeadMinutes * 60)
        )
        return RosterHomeRoutine(
            dutyID: duty.id,
            stationIATA: settings.baseIATA,
            timeZoneIdentifier: duty.startTimeZoneIdentifier,
            report: duty.start,
            leaveHome: leaveHome,
            wakeup: wakeup,
            travelMinutes: pickupLeadMinutes,
            usesDutyOverride: validOverride != nil
        )
    }
}
