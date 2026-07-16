import Foundation

struct WAIBackendConfiguration: Equatable, Sendable {
    let baseURL: URL
    let publishableKey: String

    init(baseURL: URL, publishableKey: String) throws {
        guard Self.isAllowedSupabaseURL(baseURL) else {
            throw WAIBackendConfigurationError.invalidURL
        }
        guard publishableKey.hasPrefix("sb_publishable_"),
              (24...512).contains(publishableKey.utf8.count),
              !publishableKey.contains(where: { $0.isWhitespace }) else {
            throw WAIBackendConfigurationError.invalidPublishableKey
        }

        self.baseURL = baseURL
        self.publishableKey = publishableKey
    }

    static func fromBundle(_ bundle: Bundle = .main) throws -> WAIBackendConfiguration {
        guard let rawURL = bundle.object(
            forInfoDictionaryKey: "WAISupabaseURL"
        ) as? String,
        let url = URL(string: rawURL),
        let key = bundle.object(
            forInfoDictionaryKey: "WAISupabasePublishableKey"
        ) as? String else {
            throw WAIBackendConfigurationError.missingConfiguration
        }
        return try WAIBackendConfiguration(baseURL: url, publishableKey: key)
    }

    private static func isAllowedSupabaseURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.path.isEmpty || components.path == "/",
              components.query == nil,
              components.fragment == nil,
              let host = components.host,
              host.hasSuffix(".supabase.co") else {
            return false
        }

        let projectReference = host.dropLast(".supabase.co".count)
        return (8...40).contains(projectReference.count)
        && projectReference.utf8.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
        }
    }
}

enum WAIBackendConfigurationError: Error, Equatable {
    case missingConfiguration
    case invalidURL
    case invalidPublishableKey
}

enum WAIPrivateBackendError: Error, Equatable {
    case networkUnavailable
    case unauthorized
    case forbidden
    case notFound
    case serviceUnavailable
    case invalidResponse(Int?)
    case responseTooLarge
}

protocol WAIHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

enum WAIPrivateNetworkSession {
    static let shared = URLSession(configuration: makeConfiguration())

    static func boundedData(
        for request: URLRequest,
        maximumBytes: Int = WAIPrivateHTTPResponseBuffer.hardMaximumBytes
    ) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await shared.bytes(for: request)
        var buffer = try WAIPrivateHTTPResponseBuffer(
            expectedContentLength: response.expectedContentLength,
            maximumBytes: maximumBytes
        )
        for try await byte in bytes {
            try buffer.append(byte)
        }
        return (buffer.data, response)
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        return configuration
    }
}

struct URLSessionWAIHTTPTransport: WAIHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await WAIPrivateNetworkSession.boundedData(
            for: request,
            maximumBytes: WAIPrivateHTTPResponseBuffer.hardMaximumBytes
        )
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WAIPrivateBackendError.invalidResponse(nil)
        }
        return (data, httpResponse)
    }
}

struct WAIPrivateHTTPResponseBuffer {
    static let hardMaximumBytes =
        OperationalReleaseValidator.maximumDatasetBytes

    private let maximumBytes: Int
    private(set) var data: Data

    init(
        expectedContentLength: Int64,
        maximumBytes: Int = hardMaximumBytes
    ) throws {
        guard maximumBytes > 0 else {
            throw WAIPrivateBackendError.responseTooLarge
        }
        if expectedContentLength > Int64(maximumBytes) {
            throw WAIPrivateBackendError.responseTooLarge
        }

        self.maximumBytes = maximumBytes
        data = Data()
        if expectedContentLength > 0 {
            data.reserveCapacity(Int(expectedContentLength))
        }
    }

    mutating func append(_ byte: UInt8) throws {
        guard data.count < maximumBytes else {
            throw WAIPrivateBackendError.responseTooLarge
        }
        data.append(byte)
    }
}

protocol WAIPrivateOperationalDataServing {
    func fetchActiveRelease(
        session: WAIAuthSession
    ) async throws -> OperationalReleaseManifest
    func downloadDataset(
        _ descriptor: OperationalDatasetDescriptor,
        session: WAIAuthSession
    ) async throws -> Data
}

protocol WAIProfileServing {
    func fetchProfile(session: WAIAuthSession) async throws -> WAIUserProfile
}

final class SupabaseWAIBackendClient:
    WAIPrivateOperationalDataServing,
    WAIProfileServing
{
    private let configuration: WAIBackendConfiguration
    private let transport: WAIHTTPTransport
    private let decoder: JSONDecoder

    init(
        configuration: WAIBackendConfiguration,
        transport: WAIHTTPTransport = URLSessionWAIHTTPTransport()
    ) {
        self.configuration = configuration
        self.transport = transport
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = Self.parseISO8601Date(value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO 8601 date"
                )
            }
            return date
        }
    }

    func fetchActiveRelease(
        session: WAIAuthSession
    ) async throws -> OperationalReleaseManifest {
        let url = try endpoint(
            pathComponents: ["rest", "v1", "wai_operational_releases"],
            queryItems: [
                URLQueryItem(
                    name: "select",
                    value: "contract_version,generation,minimum_app_version,datasets"
                ),
                URLQueryItem(name: "active", value: "eq.true"),
                URLQueryItem(name: "limit", value: "1")
            ]
        )
        let data = try await perform(
            request(for: url, session: session),
            maximumBytes: 262_144
        )
        guard let row = try decoder.decode([OperationalReleaseRow].self, from: data).only else {
            throw WAIPrivateBackendError.invalidResponse(nil)
        }

        let manifest = row.manifest
        try OperationalReleaseValidator.validateManifest(manifest)
        return manifest
    }

    func downloadDataset(
        _ descriptor: OperationalDatasetDescriptor,
        session: WAIAuthSession
    ) async throws -> Data {
        try OperationalReleaseValidator.validateDescriptor(descriptor)

        let objectComponents = descriptor.objectPath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        let url = try endpoint(
            pathComponents: [
                "storage", "v1", "object", "authenticated", "wai-operational-data"
            ] + objectComponents
        )
        let data = try await perform(
            request(for: url, session: session),
            maximumBytes: OperationalReleaseValidator.maximumDatasetBytes
        )
        guard data.count == descriptor.byteCount else {
            throw WAIPrivateBackendError.invalidResponse(nil)
        }
        return data
    }

    func fetchProfile(session: WAIAuthSession) async throws -> WAIUserProfile {
        let url = try endpoint(
            pathComponents: ["rest", "v1", "wai_profiles"],
            queryItems: [
                URLQueryItem(
                    name: "select",
                    value: "id,approval_code,access_status,created_at,approved_at,revoked_at"
                ),
                URLQueryItem(name: "id", value: "eq.\(session.userID.uuidString.lowercased())"),
                URLQueryItem(name: "limit", value: "1")
            ]
        )
        let data = try await perform(
            request(for: url, session: session),
            maximumBytes: 65_536
        )
        guard let profile = try decoder.decode([WAIUserProfile].self, from: data).only,
              profile.id == session.userID,
              profile.isValid else {
            throw WAIPrivateBackendError.invalidResponse(nil)
        }
        return profile
    }

    private func request(for url: URL, session: WAIAuthSession) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 20
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            configuration.publishableKey,
            forHTTPHeaderField: "apikey"
        )
        request.setValue(
            "Bearer \(session.accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        return request
    }

    private func perform(
        _ request: URLRequest,
        maximumBytes: Int
    ) async throws -> Data {
        do {
            let (data, response) = try await transport.data(for: request)
            switch response.statusCode {
            case 200...299:
                guard data.count <= maximumBytes else {
                    throw WAIPrivateBackendError.responseTooLarge
                }
                return data
            case 401:
                throw WAIPrivateBackendError.unauthorized
            case 403:
                throw WAIPrivateBackendError.forbidden
            case 404:
                throw WAIPrivateBackendError.notFound
            case 500...599:
                throw WAIPrivateBackendError.serviceUnavailable
            default:
                throw WAIPrivateBackendError.invalidResponse(response.statusCode)
            }
        } catch let error as WAIPrivateBackendError {
            throw error
        } catch is URLError {
            throw WAIPrivateBackendError.networkUnavailable
        } catch {
            throw WAIPrivateBackendError.serviceUnavailable
        }
    }

    private func endpoint(
        pathComponents: [String],
        queryItems: [URLQueryItem] = []
    ) throws -> URL {
        var url = configuration.baseURL
        for component in pathComponents {
            url.appendPathComponent(component)
        }
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            throw WAIPrivateBackendError.invalidResponse(nil)
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let result = components.url else {
            throw WAIPrivateBackendError.invalidResponse(nil)
        }
        return result
    }

    private static func parseISO8601Date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }
}

private struct OperationalReleaseRow: Decodable {
    let contractVersion: Int
    let generation: Int
    let minimumAppVersion: String
    let datasets: [OperationalDatasetDescriptor]

    var manifest: OperationalReleaseManifest {
        OperationalReleaseManifest(
            contractVersion: contractVersion,
            generation: generation,
            minimumAppVersion: minimumAppVersion,
            datasets: datasets
        )
    }

    private enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version"
        case generation
        case minimumAppVersion = "minimum_app_version"
        case datasets
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
