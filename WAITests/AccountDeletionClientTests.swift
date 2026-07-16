import Foundation
import Testing
@testable import WAI

struct SupabaseWAIAccountDeletionClientTests {
    private let userID = UUID(
        uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    )!

    @Test func sendsFreshAppleCodeOnlyToExactProtectedEndpoint() async throws {
        let transport = AccountDeletionTransportStub(
            statusCode: 200,
            body: Data(#"{"deleted":true}"#.utf8)
        )
        let client = SupabaseWAIAccountDeletionClient(
            configuration: try configuration(),
            transport: transport
        )

        try await client.deleteAccount(
            session: session(),
            authorizationCode: "single-use-code"
        )

        let request = try #require(transport.request)
        #expect(
            request.url?.absoluteString
            == "https://abcdefghijklmnopqrst.supabase.co/functions/v1/delete-account"
        )
        #expect(request.httpMethod == "POST")
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(
            request.value(forHTTPHeaderField: "Authorization")
            == "Bearer user-access-token"
        )
        #expect(
            request.value(forHTTPHeaderField: "apikey")
            == "sb_publishable_12345678901234567890"
        )
        let body = try #require(request.httpBody)
        let json = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: String]
        )
        #expect(json == ["authorization_code": "single-use-code"])
        #expect(!body.contains(Data("identity-token".utf8)))
        #expect(!body.contains(Data("refresh-token".utf8)))
    }

    @Test func successRequiresExplicitDeletedConfirmation() async {
        let transport = AccountDeletionTransportStub(
            statusCode: 200,
            body: Data(#"{"deleted":false}"#.utf8)
        )
        let client = SupabaseWAIAccountDeletionClient(
            configuration: try! configuration(),
            transport: transport
        )

        await #expect(throws: WAIAuthenticationServiceError.invalidResponse) {
            try await client.deleteAccount(
                session: session(),
                authorizationCode: "single-use-code"
            )
        }
    }

    @Test func appleAccountMismatchIsAuthenticationFailure() async {
        let transport = AccountDeletionTransportStub(
            statusCode: 403,
            body: Data(#"{"error":"apple_account_mismatch"}"#.utf8)
        )
        let client = SupabaseWAIAccountDeletionClient(
            configuration: try! configuration(),
            transport: transport
        )

        await #expect(throws: WAIAuthenticationServiceError.authenticationFailed) {
            try await client.deleteAccount(
                session: session(),
                authorizationCode: "single-use-code"
            )
        }
    }

    @Test func oversizedAppleCodeIsRejectedBeforeNetwork() async {
        let transport = AccountDeletionTransportStub(
            statusCode: 200,
            body: Data(#"{"deleted":true}"#.utf8)
        )
        let client = SupabaseWAIAccountDeletionClient(
            configuration: try! configuration(),
            transport: transport
        )

        await #expect(throws: WAIAuthenticationServiceError.authenticationFailed) {
            try await client.deleteAccount(
                session: session(),
                authorizationCode: String(repeating: "A", count: 8_193)
            )
        }
        #expect(transport.request == nil)
    }

    private func configuration() throws -> WAIBackendConfiguration {
        try WAIBackendConfiguration(
            baseURL: URL(
                string: "https://abcdefghijklmnopqrst.supabase.co"
            )!,
            publishableKey: "sb_publishable_12345678901234567890"
        )
    }

    private func session() -> WAIAuthSession {
        WAIAuthSession(
            userID: userID,
            accessToken: "user-access-token",
            refreshToken: "refresh-token",
            expiresAt: Date(timeIntervalSince1970: 1_784_116_000)
        )
    }
}

private final class AccountDeletionTransportStub: WAIHTTPTransport {
    let statusCode: Int
    let body: Data
    private(set) var request: URLRequest?

    init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }

    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        self.request = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (body, response)
    }
}
