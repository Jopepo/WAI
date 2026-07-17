import Foundation

enum WAIRosterState: Equatable, Sendable {
    case idle
    case loading
    case ready(RosterArchive)
    case importing(RosterArchive)
    case failedSecureStorage
}

enum WAIRosterImportFailure: Equatable, Sendable {
    case fileTooLarge
    case invalidFile
    case unsupportedCompany
    case invalidRoster
    case crewMismatch
    case secureStorage
}

enum WAIRosterCalendarState: Equatable, Sendable {
    case notDetermined
    case available
    case requestingAccess
    case scanning
    case accessDenied
    case restricted
    case noRosterFound
    case selectionRequired([WAIRosterCalendarOption])
    case synced(Date)
    case failed
}

enum WAIBriefingCalendarSyncState: Equatable, Sendable {
    case syncing
    case synced(calendarTitle: String)
    case removed(calendarTitle: String)
    case notAuthorized
    case sourceEventNotFound
    case readOnly
    case failed
}

private enum WAIRosterFileReadError: Error {
    case fileTooLarge
}

@MainActor
final class WAIRosterController: ObservableObject {
    @Published private(set) var state: WAIRosterState = .idle
    @Published private(set) var importFailure: WAIRosterImportFailure?
    @Published private(set) var calendarState: WAIRosterCalendarState = .notDetermined
    @Published private(set) var briefingCalendarSyncStates:
        [String: WAIBriefingCalendarSyncState] = [:]

    private let maximumImportBytes = 5 * 1_024 * 1_024
    private let store: RosterArchiveStoring
    private let calendarSource: WAIRosterCalendarSourcing
    private let now: () -> Date
    private var ownerUserID: UUID?
    private var operationID = UUID()
    private var pendingCalendarCandidates: [WAIRosterCalendarCandidate] = []
    private var didAttemptAutomaticCalendarRefresh = false
    private var lastCalendarScanAt: Date?

    init(
        store: RosterArchiveStoring,
        calendarSource: WAIRosterCalendarSourcing,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.calendarSource = calendarSource
        self.now = now
    }

    func prepare(for ownerUserID: UUID) {
        let operation = beginOperation(state: .loading)
        self.ownerUserID = ownerUserID
        importFailure = nil
        pendingCalendarCandidates = []
        didAttemptAutomaticCalendarRefresh = false
        lastCalendarScanAt = nil
        calendarState = initialCalendarState

        do {
            let archive = try store.load(for: ownerUserID) ?? RosterArchive()
            guard isCurrent(operation) else {
                return
            }
            state = .ready(archive)
        } catch ProtectedRosterStoreError.ownerMismatch {
            do {
                try store.clear()
                guard isCurrent(operation) else {
                    return
                }
                state = .ready(RosterArchive())
            } catch {
                state = .failedSecureStorage
            }
        } catch {
            guard isCurrent(operation) else {
                return
            }
            state = .failedSecureStorage
        }
    }

    func importFile(
        at url: URL,
        stationTimeZones: [String: String]
    ) async {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard url.pathExtension.caseInsensitiveCompare("ics") == .orderedSame else {
            reportImportFailure(.invalidFile)
            return
        }

        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            if let size = values.fileSize, size > maximumImportBytes {
                reportImportFailure(.fileTooLarge)
                return
            }
            let data = try readImportData(at: url)
            await importData(
                data,
                sourceName: url.lastPathComponent,
                stationTimeZones: stationTimeZones
            )
        } catch WAIRosterFileReadError.fileTooLarge {
            reportImportFailure(.fileTooLarge)
        } catch {
            reportImportFailure(.invalidFile)
        }
    }

    func connectCalendar(
        stationTimeZones: [String: String]
    ) async {
        guard let expectedOwnerUserID = ownerUserID else {
            calendarState = .failed
            return
        }
        let operation = beginOperation(state: state)

        do {
            let authorization: WAIRosterCalendarAuthorization
            switch calendarSource.authorization {
            case .notDetermined:
                calendarState = .requestingAccess
                authorization = try await calendarSource.requestFullAccess()
            case .authorized:
                authorization = .authorized
            case .denied:
                calendarState = .accessDenied
                return
            case .restricted:
                calendarState = .restricted
                return
            }

            guard isCurrent(operation),
                  ownerUserID == expectedOwnerUserID else {
                return
            }
            guard authorization == .authorized else {
                calendarState = calendarState(for: authorization)
                return
            }

            didAttemptAutomaticCalendarRefresh = true
            await scanCalendar(
                stationTimeZones: stationTimeZones,
                referenceDate: now()
            )
        } catch {
            guard isCurrent(operation),
                  ownerUserID == expectedOwnerUserID else {
                return
            }
            calendarState = .failed
        }
    }

    func refreshCalendarIfAuthorized(
        stationTimeZones: [String: String],
        force: Bool = false
    ) async {
        guard ownerUserID != nil else {
            return
        }
        guard calendarSource.authorization == .authorized else {
            calendarState = initialCalendarState
            return
        }
        guard calendarState != .scanning,
              calendarState != .requestingAccess else {
            return
        }

        let referenceDate = now()
        if !force && didAttemptAutomaticCalendarRefresh {
            return
        }
        if force,
           let lastCalendarScanAt,
           referenceDate.timeIntervalSince(lastCalendarScanAt) < 60 {
            return
        }

        didAttemptAutomaticCalendarRefresh = true
        await scanCalendar(
            stationTimeZones: stationTimeZones,
            referenceDate: referenceDate
        )
    }

    func selectCalendar(
        id: String,
        stationTimeZones: [String: String]
    ) async {
        guard let candidate = pendingCalendarCandidates.first(where: {
            $0.id == id
        }) else {
            calendarState = .failed
            return
        }

        pendingCalendarCandidates = []
        await importCalendarCandidate(
            candidate,
            stationTimeZones: stationTimeZones,
            importedAt: now()
        )
    }

    func importData(
        _ data: Data,
        sourceName: String?,
        stationTimeZones: [String: String]
    ) async {
        guard data.count <= maximumImportBytes else {
            reportImportFailure(.fileTooLarge)
            return
        }
        guard let ownerUserID else {
            reportImportFailure(.secureStorage)
            return
        }

        let previousArchive = currentArchive
        let operation = beginOperation(state: .importing(previousArchive))
        importFailure = nil

        do {
            let importedAt = now()
            let result = try await Task.detached(priority: .userInitiated) {
                try TAPRosterParser.parse(
                    data: data,
                    sourceName: sourceName,
                    stationTimeZones: stationTimeZones,
                    importedAt: importedAt
                )
            }.value
            guard isCurrent(operation) else {
                return
            }

            let archive = try previousArchive.merging(result)
            try store.save(archive, for: ownerUserID)
            guard isCurrent(operation) else {
                return
            }
            state = .ready(archive)
        } catch {
            guard isCurrent(operation) else {
                return
            }
            importFailure = mapImportFailure(error)
            state = .ready(previousArchive)
        }
    }

    func clearImportFailure() {
        importFailure = nil
    }

    func briefingCalendarSyncState(
        for legID: String
    ) -> WAIBriefingCalendarSyncState? {
        briefingCalendarSyncStates[legID]
    }

    var currentDuties: [RosterDuty] {
        currentArchive.duties
    }

    func dutyAndLeg(for legID: String) -> (RosterDuty, RosterLeg)? {
        for duty in currentArchive.duties {
            if let leg = duty.legs.first(where: { $0.id == legID }) {
                return (duty, leg)
            }
        }
        return nil
    }

    func syncBriefingToCalendar(
        duty: RosterDuty,
        leg: RosterLeg,
        plannedFlightMinutes: Int?
    ) async {
        guard ownerUserID != nil else {
            briefingCalendarSyncStates[leg.id] = .failed
            return
        }
        briefingCalendarSyncStates[leg.id] = .syncing

        do {
            let result = try calendarSource.syncBriefingEvent(
                duty: duty,
                leg: leg,
                plannedFlightMinutes: plannedFlightMinutes
            )
            briefingCalendarSyncStates[leg.id] = switch result {
            case .synced(let calendarTitle):
                .synced(calendarTitle: calendarTitle)
            case .removed(let calendarTitle):
                .removed(calendarTitle: calendarTitle)
            case .notAuthorized:
                .notAuthorized
            case .sourceEventNotFound:
                .sourceEventNotFound
            case .readOnly:
                .readOnly
            }
        } catch {
            briefingCalendarSyncStates[leg.id] = .failed
        }
    }

    func syncActualFlightToCalendar(
        duty: RosterDuty,
        leg: RosterLeg,
        actual: RosterLegActualFlightRecord,
        passengerLoad: String?
    ) async {
        guard ownerUserID != nil else {
            briefingCalendarSyncStates[leg.id] = .failed
            return
        }
        briefingCalendarSyncStates[leg.id] = .syncing

        do {
            let result = try calendarSource.syncActualFlightEvent(
                duty: duty,
                leg: leg,
                actual: actual,
                passengerLoad: passengerLoad
            )
            briefingCalendarSyncStates[leg.id] = switch result {
            case .synced(let calendarTitle):
                .synced(calendarTitle: calendarTitle)
            case .removed(let calendarTitle):
                .removed(calendarTitle: calendarTitle)
            case .notAuthorized:
                .notAuthorized
            case .sourceEventNotFound:
                .sourceEventNotFound
            case .readOnly:
                .readOnly
            }
        } catch {
            briefingCalendarSyncStates[leg.id] = .failed
        }
    }

    func reset() {
        operationID = UUID()
        ownerUserID = nil
        importFailure = nil
        calendarState = .notDetermined
        pendingCalendarCandidates = []
        briefingCalendarSyncStates = [:]
        didAttemptAutomaticCalendarRefresh = false
        lastCalendarScanAt = nil
        state = .idle
    }

    private var currentArchive: RosterArchive {
        switch state {
        case .ready(let archive), .importing(let archive):
            return archive
        case .idle, .loading, .failedSecureStorage:
            return RosterArchive()
        }
    }

    private func reportImportFailure(_ failure: WAIRosterImportFailure) {
        importFailure = failure
    }

    private func readImportData(at url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var result = Data()
        while result.count <= maximumImportBytes {
            let remaining = maximumImportBytes + 1 - result.count
            guard let chunk = try handle.read(
                upToCount: min(64 * 1_024, remaining)
            ), !chunk.isEmpty else {
                break
            }
            result.append(chunk)
        }

        guard result.count <= maximumImportBytes else {
            throw WAIRosterFileReadError.fileTooLarge
        }
        return result
    }

    private var initialCalendarState: WAIRosterCalendarState {
        calendarState(for: calendarSource.authorization)
    }

    private func calendarState(
        for authorization: WAIRosterCalendarAuthorization
    ) -> WAIRosterCalendarState {
        switch authorization {
        case .notDetermined:
            return .notDetermined
        case .authorized:
            return .available
        case .denied:
            return .accessDenied
        case .restricted:
            return .restricted
        }
    }

    private func scanCalendar(
        stationTimeZones: [String: String],
        referenceDate: Date
    ) async {
        let previousArchive = currentArchive
        let operation = beginOperation(state: .importing(previousArchive))
        importFailure = nil
        pendingCalendarCandidates = []
        calendarState = .scanning
        lastCalendarScanAt = referenceDate

        do {
            let candidates = try calendarSource.candidates(
                referenceDate: referenceDate
            )
            guard isCurrent(operation) else {
                return
            }

            guard !candidates.isEmpty else {
                state = .ready(previousArchive)
                calendarState = .noRosterFound
                return
            }

            let priorSources = Set(
                previousArchive.segments.compactMap {
                    $0.document.source.sourceName
                }
            )
            let priorMatches = candidates.filter {
                priorSources.contains($0.sourceName)
            }

            if candidates.count == 1 {
                await importCalendarCandidate(
                    candidates[0],
                    stationTimeZones: stationTimeZones,
                    importedAt: referenceDate
                )
            } else if priorMatches.count == 1 {
                await importCalendarCandidate(
                    priorMatches[0],
                    stationTimeZones: stationTimeZones,
                    importedAt: referenceDate
                )
            } else {
                pendingCalendarCandidates = candidates
                state = .ready(previousArchive)
                calendarState = .selectionRequired(
                    candidates.map(\.option)
                )
            }
        } catch {
            guard isCurrent(operation) else {
                return
            }
            state = .ready(previousArchive)
            calendarState = .failed
        }
    }

    private func importCalendarCandidate(
        _ candidate: WAIRosterCalendarCandidate,
        stationTimeZones: [String: String],
        importedAt: Date
    ) async {
        guard let ownerUserID else {
            calendarState = .failed
            return
        }

        let previousArchive = currentArchive
        let operation = beginOperation(state: .importing(previousArchive))
        calendarState = .scanning

        do {
            let payloads = candidate.payloads
            let results = try await Task.detached(priority: .userInitiated) {
                try payloads.map { payload in
                    try TAPRosterParser.parse(
                        data: payload.data,
                        sourceName: payload.sourceName,
                        stationTimeZones: stationTimeZones,
                        importedAt: importedAt
                    )
                }
            }.value
            guard isCurrent(operation) else {
                return
            }

            var archive = previousArchive
            for result in results {
                archive = try archive.merging(result)
            }
            if archive != previousArchive {
                try store.save(archive, for: ownerUserID)
            }
            guard isCurrent(operation) else {
                return
            }
            state = .ready(archive)
            calendarState = .synced(importedAt)
        } catch {
            guard isCurrent(operation) else {
                return
            }
            importFailure = mapImportFailure(error)
            state = .ready(previousArchive)
            calendarState = .failed
        }
    }

    private func mapImportFailure(_ error: Error) -> WAIRosterImportFailure {
        if let parserError = error as? TAPRosterParserError {
            switch parserError {
            case .unsupportedCompany:
                return .unsupportedCompany
            case .invalidEncoding, .malformedCalendar, .noEvents:
                return .invalidFile
            case .duplicateDutyID, .invalidEvent, .invalidFlight,
                 .invalidDocument:
                return .invalidRoster
            }
        }
        if let archiveError = error as? RosterArchiveError {
            return archiveError == .crewIdentifierMismatch
                ? .crewMismatch
                : .invalidRoster
        }
        return .secureStorage
    }

    private func beginOperation(state: WAIRosterState) -> UUID {
        let identifier = UUID()
        operationID = identifier
        self.state = state
        return identifier
    }

    private func isCurrent(_ identifier: UUID) -> Bool {
        operationID == identifier
    }
}
