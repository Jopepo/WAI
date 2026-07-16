import AuthenticationServices
import CryptoKit
import Foundation
import Security

struct WAIAppleSignInRequest: Equatable, Sendable {
    let rawNonce: String
    let hashedNonce: String
}

enum WAIAppleSignInPreparationError: Error, Equatable {
    case invalidLength
    case randomGenerationFailed
    case missingNonce
    case missingIdentityToken
    case invalidIdentityToken
    case invalidAuthorizationCode
}

struct WAIAppleSignInNonceGenerator: Sendable {
    typealias RandomBytes = @Sendable (Int) throws -> [UInt8]

    private static let characters = Array(
        "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._"
    )

    private let randomBytes: RandomBytes

    init() {
        randomBytes = { count in
            try Self.secureRandomBytes(count: count)
        }
    }

    init(randomBytes: @escaping RandomBytes) {
        self.randomBytes = randomBytes
    }

    func makeRequest(length: Int = 32) throws -> WAIAppleSignInRequest {
        guard (16...128).contains(length) else {
            throw WAIAppleSignInPreparationError.invalidLength
        }

        let characterCount = Self.characters.count
        let acceptanceLimit = (256 / characterCount) * characterCount
        var nonce = ""
        nonce.reserveCapacity(length)
        var attempts = 0

        while nonce.count < length {
            attempts += 1
            guard attempts <= 128 else {
                throw WAIAppleSignInPreparationError.randomGenerationFailed
            }

            let bytes = try randomBytes(max(length - nonce.count, 16))
            guard !bytes.isEmpty else {
                throw WAIAppleSignInPreparationError.randomGenerationFailed
            }
            for byte in bytes where Int(byte) < acceptanceLimit {
                nonce.append(Self.characters[Int(byte) % characterCount])
                if nonce.count == length {
                    break
                }
            }
        }

        return WAIAppleSignInRequest(
            rawNonce: nonce,
            hashedNonce: Self.sha256(nonce)
        )
    }

    static func sha256(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func secureRandomBytes(count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            throw WAIAppleSignInPreparationError.randomGenerationFailed
        }
        return bytes
    }
}

enum WAIAppleSignInCredentialFactory {
    static func make(
        identityToken: Data?,
        authorizationCode: Data? = nil,
        rawNonce: String?
    ) throws -> WAIAppleSignInCredential {
        guard let rawNonce,
              rawNonce == rawNonce.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ),
              (1...WAIAppleSignInCredential.maximumNonceBytes).contains(
                  rawNonce.utf8.count
              ) else {
            throw WAIAppleSignInPreparationError.missingNonce
        }
        guard let identityToken else {
            throw WAIAppleSignInPreparationError.missingIdentityToken
        }
        guard let token = String(data: identityToken, encoding: .utf8),
              token == token.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ),
              (1...WAIAppleSignInCredential.maximumIdentityTokenBytes)
                .contains(token.utf8.count) else {
            throw WAIAppleSignInPreparationError.invalidIdentityToken
        }

        let code: String?
        if let authorizationCode {
            guard let value = String(
                data: authorizationCode,
                encoding: .utf8
            ), value == value.trimmingCharacters(in: .whitespacesAndNewlines),
            (1...8_192).contains(value.utf8.count) else {
                throw WAIAppleSignInPreparationError.invalidAuthorizationCode
            }
            code = value
        } else {
            code = nil
        }

        return WAIAppleSignInCredential(
            identityToken: token,
            rawNonce: rawNonce,
            authorizationCode: code
        )
    }
}

enum WAIAppleAuthorizationErrorMapper {
    static func map(_ error: Error) -> WAIAuthenticationServiceError {
        guard let authorizationError = error as? ASAuthorizationError else {
            return .authenticationFailed
        }
        return authorizationError.code == .canceled
            ? .cancelled
            : .authenticationFailed
    }
}
