import Foundation
import Testing
@testable import WAI

struct RosterHomeRoutineBuilderTests {
    @Test func baseDepartureBuildsWakeupAndLeaveHomeFromReport() throws {
        let report = Date(timeIntervalSince1970: 1_784_243_800)
        let duty = flightDuty(
            report: report,
            originIATA: "LIS",
            timeZoneIdentifier: "Europe/Lisbon"
        )
        let settings = RosterHomeRoutineSettings(
            baseIATA: "LIS",
            travelMinutes: 35,
            wakeupBufferMinutes: 60
        )

        let routine = try #require(
            RosterHomeRoutineBuilder.routine(
                for: duty,
                settings: settings
            )
        )

        #expect(routine.report == report)
        #expect(routine.leaveHome == report.addingTimeInterval(-35 * 60))
        #expect(routine.wakeup == report.addingTimeInterval(-95 * 60))
        #expect(routine.stationIATA == "LIS")
        #expect(routine.timeZoneIdentifier == "Europe/Lisbon")
    }

    @Test func dutyAwayFromBaseDoesNotBuildHomeRoutine() {
        let duty = flightDuty(
            report: Date(timeIntervalSince1970: 1_784_243_800),
            originIATA: "CPH",
            timeZoneIdentifier: "Europe/Copenhagen"
        )
        let settings = RosterHomeRoutineSettings(
            baseIATA: "LIS",
            travelMinutes: 35,
            wakeupBufferMinutes: 60
        )

        #expect(
            RosterHomeRoutineBuilder.routine(
                for: duty,
                settings: settings
            ) == nil
        )
    }

    @Test func dutyOverrideAdjustsWakeupAndPickupIndependently() throws {
        let report = Date(timeIntervalSince1970: 1_784_243_800)
        let duty = flightDuty(
            report: report,
            originIATA: "LIS",
            timeZoneIdentifier: "Europe/Lisbon"
        )
        let settings = RosterHomeRoutineSettings(
            baseIATA: "LIS",
            travelMinutes: 35,
            wakeupBufferMinutes: 60
        )
        let override = RosterHomeRoutineOverrideRecord(
            dutyID: duty.id,
            pickupLeadMinutes: 50,
            wakeupLeadMinutes: 125,
            updatedAt: report
        )

        let routine = try #require(
            RosterHomeRoutineBuilder.routine(
                for: duty,
                settings: settings,
                override: override
            )
        )

        #expect(routine.leaveHome == report.addingTimeInterval(-50 * 60))
        #expect(routine.wakeup == report.addingTimeInterval(-125 * 60))
        #expect(routine.travelMinutes == 50)
        #expect(routine.usesDutyOverride)
    }

    private func flightDuty(
        report: Date,
        originIATA: String,
        timeZoneIdentifier: String
    ) -> RosterDuty {
        let departure = report.addingTimeInterval(60 * 60)
        let arrival = departure.addingTimeInterval(120 * 60)
        return RosterDuty(
            id: "duty-1",
            activityCode: "TEST",
            start: report,
            end: arrival.addingTimeInterval(30 * 60),
            timeZoneIdentifier: timeZoneIdentifier,
            kind: .flight,
            hotelCode: nil,
            legs: [
                RosterLeg(
                    id: "leg-1",
                    flightNumber: "TP100",
                    departure: localDateTime(
                        departure,
                        timeZoneIdentifier: timeZoneIdentifier
                    ),
                    arrival: localDateTime(
                        arrival,
                        timeZoneIdentifier: timeZoneIdentifier
                    ),
                    originIATA: originIATA,
                    originName: nil,
                    destinationIATA: "MAD",
                    destinationName: nil,
                    aircraftRegistration: nil,
                    aircraftName: nil,
                    passengerLoad: nil,
                    cosmicRadiation: nil,
                    crew: []
                )
            ]
        )
    }

    private func localDateTime(
        _ date: Date,
        timeZoneIdentifier: String
    ) -> RosterLocalDateTime {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: date
        )
        return RosterLocalDateTime(
            year: components.year!,
            month: components.month!,
            day: components.day!,
            hour: components.hour!,
            minute: components.minute!,
            timeZoneIdentifier: timeZoneIdentifier,
            instant: date
        )
    }
}

@MainActor
struct RosterPersonalizationControllerTests {
    private let ownerID = UUID(
        uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    )!
    private let now = Date(timeIntervalSince1970: 1_784_243_800)

    @Test func settingsAndBriefingPersistForTheApprovedOwner() throws {
        let store = StubRosterPersonalizationStore()
        let controller = makeController(store: store)
        controller.prepare(for: ownerID)

        #expect(
            controller.setHomeRoutine(
                baseIATA: " lis ",
                travelMinutes: 35,
                wakeupBufferMinutes: 60
            )
        )
        #expect(
            controller.setBriefing(
                for: "leg-1",
                passengerLoad: " 154 ",
                plannedFlightMinutes: 185,
                commanderPassword: " 7421 "
            )
        )
        #expect(
            controller.setHomeRoutineOverride(
                for: "duty-1",
                report: now,
                wakeup: now.addingTimeInterval(-125 * 60),
                leaveHome: now.addingTimeInterval(-50 * 60)
            )
        )

        let saved = try #require(store.snapshot)
        #expect(saved.homeRoutine?.baseIATA == "LIS")
        #expect(saved.homeRoutine?.travelMinutes == 35)
        #expect(saved.briefingRecords.first?.passengerLoad == "154")
        #expect(saved.briefingRecords.first?.plannedFlightMinutes == 185)
        #expect(saved.briefingRecords.first?.commanderPassword == "7421")
        #expect(saved.briefingRecords.first?.updatedAt == now)
        #expect(saved.homeRoutineOverrides.first?.dutyID == "duty-1")
        #expect(saved.homeRoutineOverrides.first?.pickupLeadMinutes == 50)
        #expect(saved.homeRoutineOverrides.first?.wakeupLeadMinutes == 125)
        #expect(store.savedOwner == ownerID)

        let restored = makeController(store: store)
        restored.prepare(for: ownerID)
        #expect(restored.homeRoutine == saved.homeRoutine)
        #expect(restored.briefing(for: "leg-1") == saved.briefingRecords.first)
        #expect(
            restored.homeRoutineOverride(for: "duty-1")
                == saved.homeRoutineOverrides.first
        )
    }

    @Test func legacySnapshotLoadsWithoutDutyOverrides() throws {
        let data = Data(
            #"{"schemaVersion":1,"homeRoutine":null,"briefingRecords":[]}"#.utf8
        )

        let snapshot = try JSONDecoder().decode(
            RosterPersonalizationSnapshot.self,
            from: data
        )

        #expect(snapshot.homeRoutineOverrides.isEmpty)
        #expect(snapshot.isValid)
    }

    @Test func passwordRemainsAfterMemoryResetUntilExplicitlyRemoved() throws {
        let store = StubRosterPersonalizationStore()
        let controller = makeController(store: store)
        controller.prepare(for: ownerID)
        #expect(
            controller.setBriefing(
                for: "leg-1",
                passengerLoad: "154",
                plannedFlightMinutes: nil,
                commanderPassword: "7421"
            )
        )

        controller.reset()
        #expect(controller.briefing(for: "leg-1") == nil)
        controller.prepare(for: ownerID)
        #expect(
            controller.briefing(for: "leg-1")?.commanderPassword == "7421"
        )

        #expect(
            controller.setBriefing(
                for: "leg-1",
                passengerLoad: "154",
                plannedFlightMinutes: nil,
                commanderPassword: ""
            )
        )
        #expect(controller.briefing(for: "leg-1")?.commanderPassword == nil)
        #expect(store.snapshot?.briefingRecords.first?.passengerLoad == "154")
    }

    @Test func emptyBriefingRemovesThePersonalOverride() {
        let store = StubRosterPersonalizationStore(
            snapshot: snapshot(password: "7421")
        )
        let controller = makeController(store: store)
        controller.prepare(for: ownerID)

        #expect(
            controller.setBriefing(
                for: "leg-1",
                passengerLoad: "",
                plannedFlightMinutes: nil,
                commanderPassword: ""
            )
        )

        #expect(controller.briefing(for: "leg-1") == nil)
        #expect(store.snapshot?.briefingRecords.isEmpty == true)
    }

    @Test func failedSaveKeepsThePreviouslyPublishedBriefing() {
        let existing = snapshot(password: "7421")
        let store = StubRosterPersonalizationStore(snapshot: existing)
        let controller = makeController(store: store)
        controller.prepare(for: ownerID)
        store.saveError = StubRosterPersonalizationStore.Failure.expected

        let saved = controller.setBriefing(
            for: "leg-1",
            passengerLoad: "180",
            plannedFlightMinutes: 200,
            commanderPassword: "9999"
        )

        #expect(!saved)
        #expect(controller.saveFailed)
        #expect(controller.briefing(for: "leg-1")?.passengerLoad == "154")
        #expect(
            controller.briefing(for: "leg-1")?.commanderPassword == "7421"
        )
    }

    @Test func anotherOwnersDataIsClearedBeforeUse() {
        let store = StubRosterPersonalizationStore()
        store.loadError = ProtectedManualDataStoreError.ownerMismatch
        let controller = makeController(store: store)

        controller.prepare(for: ownerID)

        #expect(store.clearCount == 1)
        #expect(controller.state == .ready)
        #expect(controller.homeRoutine == nil)
        #expect(controller.briefingRecords.isEmpty)
    }

    @Test func invalidSnapshotFailsClosed() {
        let store = StubRosterPersonalizationStore(
            snapshot: RosterPersonalizationSnapshot(
                schemaVersion: 999,
                homeRoutine: nil,
                briefingRecords: []
            )
        )
        let controller = makeController(store: store)

        controller.prepare(for: ownerID)

        #expect(controller.state == .failedSecureStorage)
        #expect(controller.homeRoutine == nil)
        #expect(controller.briefingRecords.isEmpty)
    }

    private func makeController(
        store: StubRosterPersonalizationStore
    ) -> WAIRosterPersonalizationController {
        WAIRosterPersonalizationController(store: store, now: { now })
    }

    private func snapshot(password: String) -> RosterPersonalizationSnapshot {
        RosterPersonalizationSnapshot(
            homeRoutine: nil,
            briefingRecords: [
                RosterLegBriefingRecord(
                    legID: "leg-1",
                    passengerLoad: "154",
                    plannedFlightMinutes: nil,
                    commanderPassword: password,
                    updatedAt: now
                )
            ]
        )
    }
}

struct RosterPersonalizationProtectionTests {
    private let ownerID = UUID(
        uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    )!
    private let otherOwnerID = UUID(
        uuidString: "11111111-2222-3333-4444-555555555555"
    )!

    @Test func passwordIsEncryptedOnDiskAndOwnerBound() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("personalization.bin")
        let keyStore = RosterPersonalizationTestKeyStore()
        let protectedStore = ProtectedOwnerBoundManualDataStore<
            RosterPersonalizationSnapshot
        >(
            fileURL: fileURL,
            keyStore: keyStore
        )
        let store = ProtectedRosterPersonalizationStore(store: protectedStore)
        let snapshot = RosterPersonalizationSnapshot(
            homeRoutine: RosterHomeRoutineSettings(
                baseIATA: "LIS",
                travelMinutes: 35,
                wakeupBufferMinutes: 60
            ),
            briefingRecords: [
                RosterLegBriefingRecord(
                    legID: "leg-1",
                    passengerLoad: "154",
                    plannedFlightMinutes: 185,
                    commanderPassword: "secret-7421",
                    updatedAt: Date(timeIntervalSince1970: 1_784_243_800)
                )
            ],
            homeRoutineOverrides: [
                RosterHomeRoutineOverrideRecord(
                    dutyID: "duty-private-1",
                    pickupLeadMinutes: 50,
                    wakeupLeadMinutes: 125,
                    updatedAt: Date(timeIntervalSince1970: 1_784_243_800)
                )
            ]
        )

        try store.save(snapshot, for: ownerID)

        let encrypted = try Data(contentsOf: fileURL)
        #expect(encrypted.range(of: Data("secret-7421".utf8)) == nil)
        #expect(encrypted.range(of: Data("leg-1".utf8)) == nil)
        #expect(encrypted.range(of: Data("duty-private-1".utf8)) == nil)
        #expect(try store.load(for: ownerID) == snapshot)
        #expect(throws: ProtectedManualDataStoreError.ownerMismatch) {
            _ = try store.load(for: otherOwnerID)
        }
    }
}

private final class StubRosterPersonalizationStore:
    RosterPersonalizationStoring
{
    enum Failure: Error {
        case expected
    }

    var snapshot: RosterPersonalizationSnapshot?
    var loadError: Error?
    var saveError: Error?
    var clearError: Error?
    private(set) var savedOwner: UUID?
    private(set) var clearCount = 0

    init(snapshot: RosterPersonalizationSnapshot? = nil) {
        self.snapshot = snapshot
    }

    func load(
        for ownerUserID: UUID
    ) throws -> RosterPersonalizationSnapshot? {
        if let loadError {
            throw loadError
        }
        return snapshot
    }

    func save(
        _ snapshot: RosterPersonalizationSnapshot,
        for ownerUserID: UUID
    ) throws {
        if let saveError {
            throw saveError
        }
        self.snapshot = snapshot
        savedOwner = ownerUserID
    }

    func clear() throws {
        clearCount += 1
        if let clearError {
            throw clearError
        }
        snapshot = nil
    }
}

private final class RosterPersonalizationTestKeyStore:
    ManualDataEncryptionKeyStoring
{
    private let keyData = Data(repeating: 0x5A, count: 32)

    func loadOrCreateKeyData() throws -> Data {
        keyData
    }

    func deleteKey() throws {}
}
