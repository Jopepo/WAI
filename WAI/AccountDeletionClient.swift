import Foundation

protocol WAIAccountDeletionServing {
    func deleteAccount(
        session: WAIAuthSession,
        authorizationCode: String
    ) async throws
}

final class SupabaseWAIAccountDeletionClient: WAIAccountDeletionServing {
    private struct DeletionRequest: Encodable {
        let authorizationCode: String

        private enum CodingKeys: String, CodingKey {
            case authorizationCode = "authorization_code"
        }
    }

    private struct DeletionResponse: Decodable {
        let deleted: Bool
    }

    private let configuration: WAIBackendConfiguration
    private let transport: WAIHTTPTransport
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        configuration: WAIBackendConfiguration,
        transport: WAIHTTPTransport = URLSessionWAIHTTPTransport()
    ) {
        self.configuration = configuration
        self.transport = transport
    }

    func deleteAccount(
        session: WAIAuthSession,
        authorizationCode: String
    ) async throws {
        guard session.isValid,
              authorizationCode == authorizationCode.trimmingCharacters(
                in: .whitespacesAndNewlines
              ),
              (1...8_192).contains(authorizationCode.utf8.count) else {
            throw WAIAuthenticationServiceError.authenticationFailed
        }

        let url = configuration.baseURL
            .appendingPathComponent("functions")
            .appendingPathComponent("v1")
            .appendingPathComponent("delete-account")
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )
        request.httpMethod = "POST"
        request.httpBody = try encoder.encode(
            DeletionRequest(authorizationCode: authorizationCode)
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            configuration.publishableKey,
            forHTTPHeaderField: "apikey"
        )
        request.setValue(
            "Bearer \(session.accessToken)",
            forHTTPHeaderField: "Authorization"
        )

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch is URLError {
            throw WAIAuthenticationServiceError.networkUnavailable
        } catch let error as WAIPrivateBackendError {
            throw Self.map(error)
        } catch {
            throw WAIAuthenticationServiceError.serviceUnavailable
        }

        switch response.statusCode {
        case 200...299:
            guard data.count <= 4_096,
                  let result = try? decoder.decode(
                    DeletionResponse.self,
                    from: data
                  ), result.deleted else {
                throw WAIAuthenticationServiceError.invalidResponse
            }
        case 400, 403, 409, 413, 422:
            throw WAIAuthenticationServiceError.authenticationFailed
        case 401:
            throw WAIAuthenticationServiceError.sessionUnavailable
        case 404, 429, 500...599:
            throw WAIAuthenticationServiceError.serviceUnavailable
        default:
            throw WAIAuthenticationServiceError.invalidResponse
        }
    }

    private static func map(
        _ error: WAIPrivateBackendError
    ) -> WAIAuthenticationServiceError {
        switch error {
        case .networkUnavailable:
            return .networkUnavailable
        case .unauthorized:
            return .sessionUnavailable
        case .serviceUnavailable:
            return .serviceUnavailable
        case .forbidden:
            return .authenticationFailed
        case .notFound:
            return .serviceUnavailable
        case .invalidResponse, .responseTooLarge:
            return .invalidResponse
        }
    }
}
