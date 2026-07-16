import CryptoKit
import Foundation

enum OperationalDatasetKey: String, Codable, CaseIterable, Hashable, Sendable {
    case hotelMap = "hotel_map"
    case transportRules = "transport_rules"
    case whatsNew = "whats_new"
}

struct OperationalReleaseSource: Codable, Equatable, Sendable {
    let document: String
    let revision: String
    let date: String
}

struct OperationalDatasetDescriptor: Codable, Equatable, Sendable {
    let key: OperationalDatasetKey
    let schemaVersion: String
    let source: OperationalReleaseSource
    let objectPath: String
    let sha256: String
    let byteCount: Int
}

struct OperationalReleaseManifest: Codable, Equatable, Sendable {
    let contractVersion: Int
    let generation: Int
    let minimumAppVersion: String
    let datasets: [OperationalDatasetDescriptor]
}

enum OperationalReleaseValidationError: Error, Equatable {
    case unsupportedContractVersion(Int)
    case invalidGeneration(Int)
    case invalidMinimumAppVersion(String)
    case invalidCurrentAppVersion(String)
    case minimumAppVersionNotMet(required: String, current: String)
    case incompleteDatasetSet
    case duplicateDataset(OperationalDatasetKey)
    case unsupportedSchema(OperationalDatasetKey, String)
    case invalidSource(OperationalDatasetKey)
    case invalidDigest(OperationalDatasetKey)
    case invalidByteCount(OperationalDatasetKey)
    case invalidObjectPath(OperationalDatasetKey)
    case payloadSetMismatch
    case payloadSizeMismatch(OperationalDatasetKey)
    case payloadDigestMismatch(OperationalDatasetKey)
    case payloadDecodeFailed(OperationalDatasetKey)
    case payloadSourceMismatch(OperationalDatasetKey)
    case rollback(current: Int, candidate: Int)
    case generationConflict(Int)
}

enum OperationalReleaseValidator {
    static let currentContractVersion = 1
    static let maximumDatasetBytes = 1_048_576

    private static let supportedSchemas: [OperationalDatasetKey: Set<String>] = [
        .hotelMap: ["1.0"],
        .transportRules: ["4.2"],
        .whatsNew: ["1.0"]
    ]

    static func validateManifest(_ manifest: OperationalReleaseManifest) throws {
        guard manifest.contractVersion == currentContractVersion else {
            throw OperationalReleaseValidationError.unsupportedContractVersion(
                manifest.contractVersion
            )
        }
        guard manifest.generation > 0 else {
            throw OperationalReleaseValidationError.invalidGeneration(manifest.generation)
        }
        guard isSemanticVersion(manifest.minimumAppVersion) else {
            throw OperationalReleaseValidationError.invalidMinimumAppVersion(
                manifest.minimumAppVersion
            )
        }

        let expectedKeys = Set(OperationalDatasetKey.allCases)
        let suppliedKeys = manifest.datasets.map(\.key)
        guard Set(suppliedKeys) == expectedKeys,
              suppliedKeys.count == expectedKeys.count else {
            throw OperationalReleaseValidationError.incompleteDatasetSet
        }

        var seenKeys = Set<OperationalDatasetKey>()
        for descriptor in manifest.datasets {
            guard seenKeys.insert(descriptor.key).inserted else {
                throw OperationalReleaseValidationError.duplicateDataset(descriptor.key)
            }
            try validateDescriptor(descriptor)
        }
    }

    static func validateDescriptor(
        _ descriptor: OperationalDatasetDescriptor
    ) throws {
        guard supportedSchemas[descriptor.key]?.contains(descriptor.schemaVersion) == true else {
            throw OperationalReleaseValidationError.unsupportedSchema(
                descriptor.key,
                descriptor.schemaVersion
            )
        }
        guard isValidSource(descriptor.source) else {
            throw OperationalReleaseValidationError.invalidSource(descriptor.key)
        }
        guard isSHA256(descriptor.sha256) else {
            throw OperationalReleaseValidationError.invalidDigest(descriptor.key)
        }
        guard (1...maximumDatasetBytes).contains(descriptor.byteCount) else {
            throw OperationalReleaseValidationError.invalidByteCount(descriptor.key)
        }
        guard descriptor.objectPath ==
                "\(descriptor.key.rawValue)/\(descriptor.sha256).json" else {
            throw OperationalReleaseValidationError.invalidObjectPath(descriptor.key)
        }
    }

    static func validatePackage(
        manifest: OperationalReleaseManifest,
        payloads: [OperationalDatasetKey: Data]
    ) throws {
        try validateManifest(manifest)

        let expectedKeys = Set(manifest.datasets.map(\.key))
        guard Set(payloads.keys) == expectedKeys else {
            throw OperationalReleaseValidationError.payloadSetMismatch
        }

        for descriptor in manifest.datasets {
            guard let payload = payloads[descriptor.key] else {
                throw OperationalReleaseValidationError.payloadSetMismatch
            }
            guard payload.count == descriptor.byteCount else {
                throw OperationalReleaseValidationError.payloadSizeMismatch(descriptor.key)
            }
            guard sha256(payload) == descriptor.sha256 else {
                throw OperationalReleaseValidationError.payloadDigestMismatch(descriptor.key)
            }
            try validateDocument(payload, descriptor: descriptor)
        }
    }

    static func validateCompatibility(
        _ manifest: OperationalReleaseManifest,
        currentAppVersion: String
    ) throws {
        try validateManifest(manifest)
        guard let current = semanticVersionComponents(currentAppVersion) else {
            throw OperationalReleaseValidationError.invalidCurrentAppVersion(
                currentAppVersion
            )
        }
        guard let required = semanticVersionComponents(manifest.minimumAppVersion) else {
            throw OperationalReleaseValidationError.invalidMinimumAppVersion(
                manifest.minimumAppVersion
            )
        }
        guard current.lexicographicallyPrecedes(required) == false else {
            throw OperationalReleaseValidationError.minimumAppVersionNotMet(
                required: manifest.minimumAppVersion,
                current: currentAppVersion
            )
        }
    }

    static func validateCandidate(
        _ candidate: OperationalReleaseManifest,
        replacing current: OperationalReleaseManifest?
    ) throws {
        try validateManifest(candidate)
        guard let current else {
            return
        }
        if candidate.generation < current.generation {
            throw OperationalReleaseValidationError.rollback(
                current: current.generation,
                candidate: candidate.generation
            )
        }
        if candidate.generation == current.generation && candidate != current {
            throw OperationalReleaseValidationError.generationConflict(candidate.generation)
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func validateDocument(
        _ data: Data,
        descriptor: OperationalDatasetDescriptor
    ) throws {
        let decoder = JSONDecoder()

        do {
            let source: OperationalDataDocumentSource?
            switch descriptor.key {
            case .transportRules:
                let document = try decoder.decode(StationData.self, from: data)
                guard document.isValid,
                      transportSchemaVersion(in: data) == descriptor.schemaVersion else {
                    throw OperationalReleaseValidationError.payloadDecodeFailed(descriptor.key)
                }
                source = document.sourceInfo
            case .hotelMap:
                let document = try decoder.decode(HotelDocument.self, from: data)
                guard document.isValid else {
                    throw OperationalReleaseValidationError.payloadDecodeFailed(descriptor.key)
                }
                source = document.sourceInfo
            case .whatsNew:
                let document = try decoder.decode(WhatsNewDocument.self, from: data)
                guard document.isValid else {
                    throw OperationalReleaseValidationError.payloadDecodeFailed(descriptor.key)
                }
                source = document.sourceInfo
            }

            guard source.map({ sourceMatches($0, descriptor.source) }) == true else {
                throw OperationalReleaseValidationError.payloadSourceMismatch(descriptor.key)
            }
        } catch let error as OperationalReleaseValidationError {
            throw error
        } catch {
            throw OperationalReleaseValidationError.payloadDecodeFailed(descriptor.key)
        }
    }

    private static func transportSchemaVersion(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["schemaVersion"] as? String
    }

    private static func sourceMatches(
        _ actual: OperationalDataDocumentSource,
        _ expected: OperationalReleaseSource
    ) -> Bool {
        actual.document == expected.document
        && actual.revision == expected.revision
        && actual.date == expected.date
    }

    private static func isValidSource(_ source: OperationalReleaseSource) -> Bool {
        OperationalDataDocumentSource(
            document: source.document,
            revision: source.revision,
            date: source.date
        ).isValid
    }

    private static func isSHA256(_ value: String) -> Bool {
        let bytes = value.utf8
        return bytes.count == 64
        && bytes.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }

    private static func isSemanticVersion(_ value: String) -> Bool {
        semanticVersionComponents(value) != nil
    }

    private static func semanticVersionComponents(_ value: String) -> [Int]? {
        guard value.utf8.count <= 32 else {
            return nil
        }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(components.count) else {
            return nil
        }
        guard components.allSatisfy({ component in
            (1...9).contains(component.utf8.count)
            && component.utf8.allSatisfy {
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
            }
        }) else {
            return nil
        }

        var values = components.compactMap { Int($0) }
        guard values.count == components.count else {
            return nil
        }
        while values.count < 3 {
            values.append(0)
        }
        return values
    }
}
