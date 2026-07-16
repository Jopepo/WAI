import Foundation
import Testing
@testable import WAI

@MainActor
struct WAIRosterControllerTests {
    private let ownerID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let importedAt = Date(timeIntervalSince1970: 1_784_112_400)

    @Test func prepareWithoutCacheStartsWithEmptyArchive() {
        let store = StubRosterArchiveStore()
        let controller = makeController(store: store)

        controller.prepare(for: ownerID)

        let archive = readyArchive(controller.state)
        #expect(archive?.segments.isEmpty == true)
        #expect(store.loadOwners == [ownerID])
    }

    @Test func validImportIsPersistedAtomically() async {
        let store = StubRosterArchiveStore()
        let controller = makeController(store: store)
        controller.prepare(for: ownerID)

        await controller.importData(
            Data(activityCalendar.utf8),
            sourceName: "roster.ics",
            stationTimeZones: [:]
        )

        let archive = readyArchive(controller.state)
        #expect(archive?.segments.count == 1)
        #expect(archive?.duties.first?.activityCode == "DFD")
        #expect(store.savedArchive == archive)
        #expect(store.savedOwner == ownerID)
        #expect(controller.importFailure == nil)
    }

    @Test func badUpdateKeepsEarlierRosterVisible() async throws {
        let initial = try parsedArchive()
        let store = StubRosterArchiveStore(archive: initial)
        let controller = makeController(store: store)
        controller.prepare(for: ownerID)

        await controller.importData(
            Data("not an iCalendar file".utf8),
            sourceName: "broken.ics",
            stationTimeZones: [:]
        )

        #expect(readyArchive(controller.state) == initial)
        #expect(controller.importFailure == .invalidFile)
        #expect(store.saveCount == 0)
    }

    @Test func secureSaveFailureKeepsEarlierRosterVisible() async throws {
        let initial = try parsedArchive()
        let store = StubRosterArchiveStore(archive: initial)
        store.saveError = StubRosterArchiveStore.Failure.expected
        let controller = makeController(store: store)
        controller.prepare(for: ownerID)

        await controller.importData(
            Data(updatedActivityCalendar.utf8),
            sourceName: "updated.ics",
            stationTimeZones: [:]
        )

        #expect(readyArchive(controller.state) == initial)
        #expect(controller.importFailure == .secureStorage)
        #expect(store.saveCount == 1)
    }

    @Test func oversizedImportIsRejectedBeforeParsing() async {
        let store = StubRosterArchiveStore()
        let controller = makeController(store: store)
        controller.prepare(for: ownerID)

        await controller.importData(
            Data(repeating: 0x41, count: 5 * 1_024 * 1_024 + 1),
            sourceName: "large.ics",
            stationTimeZones: [:]
        )

        #expect(controller.importFailure == .fileTooLarge)
        #expect(readyArchive(controller.state)?.segments.isEmpty == true)
        #expect(store.saveCount == 0)
    }

    @Test func oversizedFileImportIsRejectedWithoutParsing() async throws {
        let store = StubRosterArchiveStore()
        let controller = makeController(store: store)
        controller.prepare(for: ownerID)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).ics")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data(
            repeating: 0x41,
            count: 5 * 1_024 * 1_024 + 1
        ).write(to: fileURL)

        await controller.importFile(
            at: fileURL,
            stationTimeZones: [:]
        )

        #expect(controller.importFailure == .fileTooLarge)
        #expect(readyArchive(controller.state)?.segments.isEmpty == true)
        #expect(store.saveCount == 0)
    }

    @Test func cacheFromAnotherOwnerIsDestroyedBeforeUse() {
        let store = StubRosterArchiveStore()
        store.loadError = ProtectedRosterStoreError.ownerMismatch
        let controller = makeController(store: store)

        controller.prepare(for: ownerID)

        #expect(store.clearCount == 1)
        #expect(readyArchive(controller.state)?.segments.isEmpty == true)
    }

    @Test func resetDropsAllInMemoryRosterState() async {
        let store = StubRosterArchiveStore()
        let controller = makeController(store: store)
        controller.prepare(for: ownerID)
        await controller.importData(
            Data(activityCalendar.utf8),
            sourceName: "roster.ics",
            stationTimeZones: [:]
        )

        controller.reset()

        #expect(controller.state == .idle)
        #expect(controller.importFailure == nil)
    }

    @Test func connectRequestsAccessAndImportsSingleRoster() async {
        let store = StubRosterArchiveStore()
        let calendarSource = StubRosterCalendarSource()
        calendarSource.foundCandidates = [
            calendarCandidate(id: "calendar-a", title: "Escala TAP")
        ]
        let controller = makeController(
            store: store,
            calendarSource: calendarSource
        )
        controller.prepare(for: ownerID)

        await controller.connectCalendar(stationTimeZones: [:])

        #expect(calendarSource.requestCount == 1)
        #expect(calendarSource.candidateReferenceDates == [importedAt])
        #expect(readyArchive(controller.state)?.duties.first?.activityCode == "DFD")
        #expect(store.saveCount == 1)
        #expect(controller.calendarState == .synced(importedAt))
    }

    @Test func deniedCalendarAccessDoesNotReadEvents() async {
        let store = StubRosterArchiveStore()
        let calendarSource = StubRosterCalendarSource()
        calendarSource.requestedAuthorization = .denied
        let controller = makeController(
            store: store,
            calendarSource: calendarSource
        )
        controller.prepare(for: ownerID)

        await controller.connectCalendar(stationTimeZones: [:])

        #expect(calendarSource.requestCount == 1)
        #expect(calendarSource.candidateReferenceDates.isEmpty)
        #expect(controller.calendarState == .accessDenied)
        #expect(readyArchive(controller.state)?.segments.isEmpty == true)
        #expect(store.saveCount == 0)
    }

    @Test func delayedCalendarAuthorizationCannotResumeAfterReset() async {
        let store = StubRosterArchiveStore()
        let calendarSource = StubRosterCalendarSource()
        calendarSource.shouldSuspendRequest = true
        calendarSource.foundCandidates = [
            calendarCandidate(id: "calendar-a", title: "Escala TAP")
        ]
        let controller = makeController(
            store: store,
            calendarSource: calendarSource
        )
        controller.prepare(for: ownerID)

        let connection = Task {
            await controller.connectCalendar(stationTimeZones: [:])
        }
        while calendarSource.requestCount == 0 {
            await Task.yield()
        }

        controller.reset()
        calendarSource.resumeRequest()
        await connection.value

        #expect(controller.state == .idle)
        #expect(controller.calendarState == .notDetermined)
        #expect(calendarSource.candidateReferenceDates.isEmpty)
        #expect(store.saveCount == 0)
    }

    @Test func automaticCalendarRefreshRunsOncePerPreparation() async {
        let store = StubRosterArchiveStore()
        let calendarSource = StubRosterCalendarSource()
        calendarSource.authorization = .authorized
        let controller = makeController(
            store: store,
            calendarSource: calendarSource
        )
        controller.prepare(for: ownerID)

        await controller.refreshCalendarIfAuthorized(stationTimeZones: [:])
        await controller.refreshCalendarIfAuthorized(stationTimeZones: [:])

        #expect(calendarSource.candidateReferenceDates == [importedAt])
        #expect(controller.calendarState == .noRosterFound)
        #expect(readyArchive(controller.state)?.segments.isEmpty == true)
    }

    @Test func multipleCalendarsRequireExplicitSelection() async {
        let store = StubRosterArchiveStore()
        let calendarSource = StubRosterCalendarSource()
        calendarSource.authorization = .authorized
        calendarSource.foundCandidates = [
            calendarCandidate(id: "calendar-a", title: "Old", code: "DFD"),
            calendarCandidate(id: "calendar-b", title: "Current", code: "DOE")
        ]
        let controller = makeController(
            store: store,
            calendarSource: calendarSource
        )
        controller.prepare(for: ownerID)

        await controller.connectCalendar(stationTimeZones: [:])

        guard case .selectionRequired(let options) = controller.calendarState else {
            Issue.record("Expected calendar selection")
            return
        }
        #expect(options.map(\.id) == ["calendar-a", "calendar-b"])
        #expect(store.saveCount == 0)

        await controller.selectCalendar(
            id: "calendar-b",
            stationTimeZones: [:]
        )

        #expect(readyArchive(controller.state)?.duties.first?.activityCode == "DOE")
        #expect(store.saveCount == 1)
        #expect(controller.calendarState == .synced(importedAt))
    }

    @Test func calendarBatchImportIsAtomicWhenOneMonthIsInvalid() async {
        let store = StubRosterArchiveStore()
        let calendarSource = StubRosterCalendarSource()
        calendarSource.authorization = .authorized
        let valid = WAIRosterCalendarPayload(
            data: Data(activityCalendar.utf8),
            sourceName: "Calendar - Escala TAP"
        )
        let invalid = WAIRosterCalendarPayload(
            data: Data("not a calendar".utf8),
            sourceName: "Calendar - Escala TAP"
        )
        calendarSource.foundCandidates = [
            WAIRosterCalendarCandidate(
                id: "calendar-a",
                title: "Escala TAP",
                eventCount: 2,
                start: importedAt,
                end: importedAt.addingTimeInterval(7_200),
                payloads: [valid, invalid]
            )
        ]
        let controller = makeController(
            store: store,
            calendarSource: calendarSource
        )
        controller.prepare(for: ownerID)

        await controller.connectCalendar(stationTimeZones: [:])

        #expect(readyArchive(controller.state)?.segments.isEmpty == true)
        #expect(controller.importFailure == .invalidFile)
        #expect(controller.calendarState == .failed)
        #expect(store.saveCount == 0)
    }

    private func makeController(
        store: StubRosterArchiveStore
    ) -> WAIRosterController {
        makeController(
            store: store,
            calendarSource: StubRosterCalendarSource()
        )
    }

    private func makeController(
        store: StubRosterArchiveStore,
        calendarSource: StubRosterCalendarSource
    ) -> WAIRosterController {
        WAIRosterController(
            store: store,
            calendarSource: calendarSource,
            now: { importedAt }
        )
    }

    private func parsedArchive() throws -> RosterArchive {
        let result = try TAPRosterParser.parse(
            data: Data(activityCalendar.utf8),
            sourceName: "roster.ics",
            stationTimeZones: [:],
            importedAt: importedAt
        )
        return try RosterArchive().merging(result)
    }

    private func readyArchive(_ state: WAIRosterState) -> RosterArchive? {
        guard case .ready(let archive) = state else {
            return nil
        }
        return archive
    }

    private func calendarCandidate(
        id: String,
        title: String,
        code: String = "DFD"
    ) -> WAIRosterCalendarCandidate {
        let calendar = activityCalendar
            .replacingOccurrences(of: "SUMMARY:DFD", with: "SUMMARY:\(code)")
            .replacingOccurrences(
                of: "DESCRIPTION:ACTIVIDADE: DFD",
                with: "DESCRIPTION:ACTIVIDADE: \(code)"
            )
            .replacingOccurrences(of: "UID:duty-1", with: "UID:duty-\(id)")
        return WAIRosterCalendarCandidate(
            id: id,
            title: title,
            eventCount: 1,
            start: importedAt,
            end: importedAt.addingTimeInterval(3_600),
            payloads: [
                WAIRosterCalendarPayload(
                    data: Data(calendar.utf8),
                    sourceName: "Calendar - \(title)"
                )
            ]
        )
    }

    private var activityCalendar: String {
        """
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//TAP Portugal - Portal DOV
        X-WR-CALNAME:Escala TAP 01-07-2026 a 31-07-2026
        X-WR-CALDESC:Escala TAP do Tripulante 12345.6
        BEGIN:VEVENT
        TZID:Europe-Lisbon
        DTSTART:20260701T100000
        DTEND:20260702T100000
        SUMMARY:DFD
        DESCRIPTION:ACTIVIDADE: DFD
        UID:duty-1
        END:VEVENT
        END:VCALENDAR
        """
    }

    private var updatedActivityCalendar: String {
        activityCalendar
            .replacingOccurrences(of: "SUMMARY:DFD", with: "SUMMARY:DOE")
            .replacingOccurrences(
                of: "DESCRIPTION:ACTIVIDADE: DFD",
                with: "DESCRIPTION:ACTIVIDADE: DOE"
            )
    }
}

@MainActor
private final class StubRosterCalendarSource: WAIRosterCalendarSourcing {
    var authorization: WAIRosterCalendarAuthorization = .notDetermined
    var requestedAuthorization: WAIRosterCalendarAuthorization = .authorized
    var foundCandidates: [WAIRosterCalendarCandidate] = []
    var requestError: Error?
    var candidatesError: Error?
    var shouldSuspendRequest = false
    private(set) var requestCount = 0
    private(set) var candidateReferenceDates: [Date] = []
    private var requestContinuation:
        CheckedContinuation<WAIRosterCalendarAuthorization, Error>?

    func requestFullAccess() async throws -> WAIRosterCalendarAuthorization {
        requestCount += 1
        if let requestError {
            throw requestError
        }
        if shouldSuspendRequest {
            return try await withCheckedThrowingContinuation { continuation in
                requestContinuation = continuation
            }
        }
        authorization = requestedAuthorization
        return requestedAuthorization
    }

    func resumeRequest() {
        authorization = requestedAuthorization
        requestContinuation?.resume(returning: requestedAuthorization)
        requestContinuation = nil
    }

    func candidates(
        referenceDate: Date
    ) throws -> [WAIRosterCalendarCandidate] {
        candidateReferenceDates.append(referenceDate)
        if let candidatesError {
            throw candidatesError
        }
        return foundCandidates
    }
}

private final class StubRosterArchiveStore: RosterArchiveStoring {
    enum Failure: Error {
        case expected
    }

    var archive: RosterArchive?
    var loadError: Error?
    var saveError: Error?
    var clearError: Error?
    private(set) var loadOwners: [UUID] = []
    private(set) var savedArchive: RosterArchive?
    private(set) var savedOwner: UUID?
    private(set) var saveCount = 0
    private(set) var clearCount = 0

    init(archive: RosterArchive? = nil) {
        self.archive = archive
    }

    func load(for ownerUserID: UUID) throws -> RosterArchive? {
        loadOwners.append(ownerUserID)
        if let loadError {
            throw loadError
        }
        return archive
    }

    func save(_ archive: RosterArchive, for ownerUserID: UUID) throws {
        saveCount += 1
        if let saveError {
            throw saveError
        }
        self.archive = archive
        savedArchive = archive
        savedOwner = ownerUserID
    }

    func clear() throws {
        clearCount += 1
        if let clearError {
            throw clearError
        }
        archive = nil
    }
}
