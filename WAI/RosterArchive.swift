import Foundation

enum RosterArchiveError: Error, Equatable {
    case invalidImport
    case invalidArchive
    case crewIdentifierMismatch
}

struct RosterImportSegment: Codable, Equatable, Sendable, Identifiable {
    let document: RosterDocument
    let issues: [RosterImportIssue]

    var id: String {
        let coverage = document.coverage
        let crew = document.source.crewIdentifier ?? "unknown"
        return [
            document.source.company.rawValue,
            crew,
            String(Int64(coverage.start.timeIntervalSince1970)),
            String(Int64(coverage.end.timeIntervalSince1970)),
            coverage.timeZoneIdentifier
        ].joined(separator: "|")
    }

    var isValid: Bool {
        guard document.isValid,
              issues.count <= 10_000,
              issues.allSatisfy(\.isValid),
              Set(issues.map(\.id)).count == issues.count else {
            return false
        }

        let duties = Dictionary(
            uniqueKeysWithValues: document.duties.map { ($0.id, $0) }
        )
        return issues.allSatisfy { issue in
            guard let duty = duties[issue.dutyID] else {
                return false
            }
            return duty.legs.contains { leg in
                leg.flightNumber == issue.flightNumber
                && (leg.originIATA == issue.stationIATA
                    || leg.destinationIATA == issue.stationIATA)
            }
        }
    }
}

struct RosterArchive: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let segments: [RosterImportSegment]

    init(
        schemaVersion: Int = currentSchemaVersion,
        segments: [RosterImportSegment] = []
    ) {
        self.schemaVersion = schemaVersion
        self.segments = segments
    }

    var isValid: Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              segments.count <= 120,
              segments.allSatisfy(\.isValid),
              Set(segments.map(\.id)).count == segments.count else {
            return false
        }

        let crewIdentifiers = Set(
            segments.compactMap { $0.document.source.crewIdentifier }
        )
        return crewIdentifiers.count <= 1
    }

    var duties: [RosterDuty] {
        activeDutyRecords.values.map(\.duty).sorted {
            if $0.start == $1.start {
                return $0.id < $1.id
            }
            return $0.start < $1.start
        }
    }

    var issues: [RosterImportIssue] {
        let segmentsByID = Dictionary(
            uniqueKeysWithValues: segments.map { ($0.id, $0) }
        )
        let activeIssues = activeDutyRecords.values.flatMap { record in
            segmentsByID[record.segmentID]?.issues.filter {
                $0.dutyID == record.duty.id
            } ?? []
        }
        return Array(Set(activeIssues)).sorted { $0.id < $1.id }
    }

    private struct ActiveDutyRecord {
        let duty: RosterDuty
        let segmentID: String
    }

    private var activeDutyRecords: [String: ActiveDutyRecord] {
        let importGroups = Dictionary(
            grouping: segments,
            by: { $0.document.source.importedAt }
        )
        .sorted { $0.key < $1.key }
        var active: [String: ActiveDutyRecord] = [:]

        for (_, group) in importGroups {
            let coverages = group.map(\.document.coverage)
            active = active.filter { _, record in
                !coverages.contains { coverage in
                    record.duty.start >= coverage.start
                    && record.duty.start < coverage.end
                }
            }

            for segment in group.sorted(by: { $0.id < $1.id }) {
                for duty in segment.document.duties {
                    active[duty.id] = ActiveDutyRecord(
                        duty: duty,
                        segmentID: segment.id
                    )
                }
            }
        }

        return active
    }

    func merging(_ result: RosterImportResult) throws -> RosterArchive {
        let incoming = RosterImportSegment(
            document: result.document,
            issues: result.issues
        )
        guard incoming.isValid else {
            throw RosterArchiveError.invalidImport
        }

        let existingCrewIdentifiers = Set(
            segments.compactMap { $0.document.source.crewIdentifier }
        )
        if let incomingCrew = incoming.document.source.crewIdentifier,
           !existingCrewIdentifiers.isEmpty,
           !existingCrewIdentifiers.contains(incomingCrew) {
            throw RosterArchiveError.crewIdentifierMismatch
        }

        if segments.contains(where: {
            $0.document.source.sha256 == incoming.document.source.sha256
        }) {
            return self
        }

        var updated = segments.filter { $0.id != incoming.id }
        updated.append(incoming)
        updated.sort {
            let first = $0.document.coverage
            let second = $1.document.coverage
            if first.start == second.start {
                return first.end < second.end
            }
            return first.start < second.start
        }

        let archive = RosterArchive(segments: updated)
        guard archive.isValid else {
            throw RosterArchiveError.invalidArchive
        }
        return archive
    }
}
