import Foundation
import Testing
@testable import WAI

struct RosterArchiveTests {
    private let ownerID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let otherOwnerID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let firstImportDate = Date(timeIntervalSince1970: 1_780_000_000)
    private let secondImportDate = Date(timeIntervalSince1970: 1_781_000_000)

    @Test func newerImportReplacesTheSameCoveragePeriod() throws {
        let first = makeResult(
            digestCharacter: "a",
            importedAt: firstImportDate,
            passengerLoad: "1/0/100"
        )
        let second = makeResult(
            digestCharacter: "b",
            importedAt: secondImportDate,
            passengerLoad: "2/0/120"
        )

        let archive = try RosterArchive()
            .merging(first)
            .merging(second)

        #expect(archive.isValid)
        #expect(archive.segments.count == 1)
        #expect(archive.duties.count == 1)
        #expect(archive.duties.first?.legs.first?.passengerLoad == "2/0/120")
        #expect(archive.segments.first?.document.source.sha256 == String(repeating: "b", count: 64))
    }

    @Test func identicalFileIsIdempotent() throws {
        let result = makeResult(
            digestCharacter: "a",
            importedAt: firstImportDate,
            passengerLoad: "1/0/100"
        )

        let once = try RosterArchive().merging(result)
        let twice = try once.merging(result)

        #expect(twice == once)
        #expect(twice.segments.count == 1)
    }

    @Test func differentCoveragePeriodsAreRetained() throws {
        let july = makeResult(
            digestCharacter: "a",
            importedAt: firstImportDate,
            passengerLoad: "1/0/100"
        )
        let august = makeResult(
            digestCharacter: "b",
            importedAt: secondImportDate,
            passengerLoad: "2/0/120",
            dayOffset: 31,
            dutyID: "duty-august"
        )

        let archive = try RosterArchive()
            .merging(july)
            .merging(august)

        #expect(archive.segments.count == 2)
        #expect(archive.duties.map(\.id) == ["duty-july", "duty-august"])
    }

    @Test func newerOverlappingCoverageRemovesCancelledDuties() throws {
        let julyFirst = utcDate(2026, 7, 1)
        let julyTenth = utcDate(2026, 7, 10)
        let julyFifteenth = utcDate(2026, 7, 15)
        let julyTwentieth = utcDate(2026, 7, 20)
        let julyTwentyFifth = utcDate(2026, 7, 25)
        let augustFirst = utcDate(2026, 8, 1)
        let augustFifteenth = utcDate(2026, 8, 15)

        let earlier = makeActivityResult(
            digestCharacter: "a",
            importedAt: firstImportDate,
            coverageStart: julyFirst,
            coverageEnd: augustFirst,
            duties: [
                activityDuty(id: "outside-update", start: julyTenth),
                activityDuty(id: "cancelled", start: julyTwentieth)
            ]
        )
        let update = makeActivityResult(
            digestCharacter: "b",
            importedAt: secondImportDate,
            coverageStart: julyFifteenth,
            coverageEnd: augustFifteenth,
            duties: [
                activityDuty(id: "new-duty", start: julyTwentyFifth)
            ]
        )

        let archive = try RosterArchive()
            .merging(earlier)
            .merging(update)

        #expect(archive.segments.count == 2)
        #expect(archive.duties.map(\.id) == ["outside-update", "new-duty"])
    }

    @Test func stableCarryInDutyIsReplacedAcrossAdjacentImports() throws {
        let juneFirst = utcDate(2026, 6, 1)
        let julyFirst = utcDate(2026, 7, 1)
        let augustFirst = utcDate(2026, 8, 1)
        let carryInStart = julyFirst.addingTimeInterval(-14 * 3_600)

        let june = makeActivityResult(
            digestCharacter: "a",
            importedAt: firstImportDate,
            coverageStart: juneFirst,
            coverageEnd: julyFirst,
            duties: [
                activityDuty(
                    id: "stable-carry-in",
                    start: carryInStart,
                    end: julyFirst.addingTimeInterval(10 * 3_600)
                )
            ]
        )
        let july = makeActivityResult(
            digestCharacter: "b",
            importedAt: secondImportDate,
            coverageStart: julyFirst,
            coverageEnd: augustFirst,
            duties: [
                activityDuty(
                    id: "stable-carry-in",
                    start: carryInStart,
                    end: julyFirst.addingTimeInterval(11 * 3_600)
                )
            ]
        )

        let archive = try RosterArchive()
            .merging(june)
            .merging(july)

        #expect(archive.isValid)
        #expect(archive.duties.count == 1)
        #expect(
            archive.duties.first?.end
                == julyFirst.addingTimeInterval(11 * 3_600)
        )
    }

    @Test func nextMonthDoesNotDeletePriorCarryOutWhenAbsent() throws {
        let julyFirst = utcDate(2026, 7, 1)
        let augustFirst = utcDate(2026, 8, 1)
        let septemberFirst = utcDate(2026, 9, 1)
        let carryOutStart = augustFirst.addingTimeInterval(-2 * 3_600)

        let july = makeActivityResult(
            digestCharacter: "a",
            importedAt: firstImportDate,
            coverageStart: julyFirst,
            coverageEnd: augustFirst,
            duties: [
                activityDuty(
                    id: "carry-out",
                    start: carryOutStart,
                    end: augustFirst.addingTimeInterval(8 * 3_600)
                )
            ]
        )
        let august = makeActivityResult(
            digestCharacter: "b",
            importedAt: secondImportDate,
            coverageStart: augustFirst,
            coverageEnd: septemberFirst,
            duties: [
                activityDuty(
                    id: "august-duty",
                    start: augustFirst.addingTimeInterval(24 * 3_600)
                )
            ]
        )

        let archive = try RosterArchive()
            .merging(july)
            .merging(august)

        #expect(archive.isValid)
        #expect(archive.duties.map(\.id) == ["carry-out", "august-duty"])
    }

    @Test func anotherCrewRosterCannotBeMixedIntoArchive() throws {
        let first = makeResult(
            digestCharacter: "a",
            importedAt: firstImportDate,
            passengerLoad: nil
        )
        let otherCrew = makeResult(
            digestCharacter: "b",
            importedAt: secondImportDate,
            passengerLoad: nil,
            crewIdentifier: "99999.9"
        )
        let archive = try RosterArchive().merging(first)

        #expect(throws: RosterArchiveError.crewIdentifierMismatch) {
            try archive.merging(otherCrew)
        }
    }

    @Test func encryptedStoreRoundTripsAndBindsOwner() throws {
        let fixture = try makeStoreFixture()
        let archive = try RosterArchive().merging(
            makeResult(
                digestCharacter: "a",
                importedAt: firstImportDate,
                passengerLoad: "PRIVATE-LOAD"
            )
        )

        try fixture.store.save(archive, for: ownerID)

        #expect(try fixture.store.load(for: ownerID) == archive)
        #expect(throws: ProtectedRosterStoreError.ownerMismatch) {
            try fixture.store.load(for: otherOwnerID)
        }
        let encrypted = try Data(contentsOf: fixture.fileURL)
        #expect(String(data: encrypted, encoding: .utf8)?.contains("PRIVATE-LOAD") != true)
        #expect(fixture.keyStore.keyData?.count == 32)
    }

    @Test func encryptedStoreRejectsTampering() throws {
        let fixture = try makeStoreFixture()
        let archive = try RosterArchive().merging(
            makeResult(
                digestCharacter: "a",
                importedAt: firstImportDate,
                passengerLoad: nil
            )
        )
        try fixture.store.save(archive, for: ownerID)

        var encrypted = try Data(contentsOf: fixture.fileURL)
        encrypted[encrypted.startIndex] ^= 0x01
        try encrypted.write(to: fixture.fileURL, options: .atomic)

        #expect(throws: (any Error).self) {
            try fixture.store.load(for: ownerID)
        }
    }

    @Test func clearDeletesEncryptedFileAndKey() throws {
        let fixture = try makeStoreFixture()
        let archive = try RosterArchive().merging(
            makeResult(
                digestCharacter: "a",
                importedAt: firstImportDate,
                passengerLoad: nil
            )
        )
        try fixture.store.save(archive, for: ownerID)

        try fixture.store.clear()

        #expect(!FileManager.default.fileExists(atPath: fixture.fileURL.path))
        #expect(fixture.keyStore.keyData == nil)
        #expect(fixture.keyStore.deleteCount == 1)
    }

    @Test func sensitiveStoreGroupAttemptsEveryClear() {
        let failing = SensitiveClearSpy(shouldFail: true)
        let succeeding = SensitiveClearSpy(shouldFail: false)
        let group = WAISensitiveDataStoreGroup([failing, succeeding])

        #expect(throws: SensitiveClearSpy.Failure.self) {
            try group.clear()
        }
        #expect(failing.clearCount == 1)
        #expect(succeeding.clearCount == 1)
    }

    private func makeResult(
        digestCharacter: Character,
        importedAt: Date,
        passengerLoad: String?,
        dayOffset: Int = 0,
        dutyID: String = "duty-july",
        crewIdentifier: String = "12345.6"
    ) -> RosterImportResult {
        let start = utcDate(2026, 7, 1).addingTimeInterval(
            TimeInterval(dayOffset * 86_400)
        )
        let end = start.addingTimeInterval(31 * 86_400)
        let departure = start.addingTimeInterval(10 * 3_600)
        let arrival = departure.addingTimeInterval(2 * 3_600)
        let localDeparture = RosterLocalDateTime(
            year: 2026,
            month: dayOffset == 0 ? 7 : 8,
            day: 1,
            hour: 10,
            minute: 0,
            timeZoneIdentifier: "UTC",
            instant: departure
        )
        let localArrival = RosterLocalDateTime(
            year: 2026,
            month: dayOffset == 0 ? 7 : 8,
            day: 1,
            hour: 12,
            minute: 0,
            timeZoneIdentifier: "UTC",
            instant: arrival
        )
        let leg = RosterLeg(
            id: "\(dutyID)-0-TP0001",
            flightNumber: "TP0001",
            departure: localDeparture,
            arrival: localArrival,
            originIATA: "LIS",
            originName: "Lisbon",
            destinationIATA: "CPH",
            destinationName: "Copenhagen",
            aircraftRegistration: nil,
            aircraftName: nil,
            passengerLoad: passengerLoad,
            cosmicRadiation: nil,
            crew: []
        )
        let duty = RosterDuty(
            id: dutyID,
            activityCode: "1CPH0001P",
            start: departure.addingTimeInterval(-3_600),
            end: arrival.addingTimeInterval(1_800),
            timeZoneIdentifier: "UTC",
            kind: .flight,
            hotelCode: nil,
            legs: [leg]
        )
        let source = RosterSource(
            company: .tap,
            productIdentifier: "TAP Portal DOV",
            calendarName: "Sanitized roster",
            crewIdentifier: crewIdentifier,
            sourceName: "roster.ics",
            sha256: String(repeating: digestCharacter, count: 64),
            importedAt: importedAt
        )
        let document = RosterDocument(
            source: source,
            coverage: RosterCoveragePeriod(
                start: start,
                end: end,
                timeZoneIdentifier: "UTC"
            ),
            duties: [duty]
        )
        return RosterImportResult(document: document, issues: [])
    }

    private func makeActivityResult(
        digestCharacter: Character,
        importedAt: Date,
        coverageStart: Date,
        coverageEnd: Date,
        duties: [RosterDuty]
    ) -> RosterImportResult {
        let source = RosterSource(
            company: .tap,
            productIdentifier: "TAP Portal DOV",
            calendarName: "Sanitized roster",
            crewIdentifier: "12345.6",
            sourceName: "roster.ics",
            sha256: String(repeating: digestCharacter, count: 64),
            importedAt: importedAt
        )
        return RosterImportResult(
            document: RosterDocument(
                source: source,
                coverage: RosterCoveragePeriod(
                    start: coverageStart,
                    end: coverageEnd,
                    timeZoneIdentifier: "UTC"
                ),
                duties: duties
            ),
            issues: []
        )
    }

    private func activityDuty(id: String, start: Date) -> RosterDuty {
        activityDuty(
            id: id,
            start: start,
            end: start.addingTimeInterval(3_600)
        )
    }

    private func activityDuty(
        id: String,
        start: Date,
        end: Date
    ) -> RosterDuty {
        RosterDuty(
            id: id,
            activityCode: "DFD",
            start: start,
            end: end,
            timeZoneIdentifier: "UTC",
            kind: .activity,
            hotelCode: nil,
            legs: []
        )
    }

    private func makeStoreFixture() throws -> RosterStoreFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let fileURL = directory.appendingPathComponent("roster.cache")
        let keyStore = MemoryRosterKeyStore()
        let store = ProtectedRosterStore(
            fileURL: fileURL,
            keyStore: keyStore
        )
        return RosterStoreFixture(
            store: store,
            keyStore: keyStore,
            fileURL: fileURL
        )
    }

    private func utcDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day
        ))!
    }
}

private struct RosterStoreFixture {
    let store: ProtectedRosterStore
    let keyStore: MemoryRosterKeyStore
    let fileURL: URL
}

private final class MemoryRosterKeyStore: RosterEncryptionKeyStoring {
    var keyData: Data?
    private(set) var deleteCount = 0

    func loadOrCreateKeyData() throws -> Data {
        if let keyData {
            return keyData
        }
        let generated = Data(repeating: 0x42, count: 32)
        keyData = generated
        return generated
    }

    func deleteKey() throws {
        deleteCount += 1
        keyData = nil
    }
}

private final class SensitiveClearSpy: WAISensitiveOperationalDataClearing {
    enum Failure: Error {
        case expected
    }

    let shouldFail: Bool
    private(set) var clearCount = 0

    init(shouldFail: Bool) {
        self.shouldFail = shouldFail
    }

    func clear() throws {
        clearCount += 1
        if shouldFail {
            throw Failure.expected
        }
    }
}
