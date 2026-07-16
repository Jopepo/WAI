import Foundation

enum WAI3ConfigurationError: Error, Equatable {
    case missingBackendConfiguration
    case invalidApprovalEmail
    case invalidPrivacyPolicyURL
    case invalidCompatibilityVersion
}

struct WAI3SecureConfiguration: Equatable, Sendable {
    let backend: WAIBackendConfiguration
    let approvalEmail: String
    let privacyPolicyURL: URL
    let compatibilityVersion: String

    init(
        backend: WAIBackendConfiguration,
        approvalEmail: String,
        privacyPolicyURL: URL,
        compatibilityVersion: String = "3.0"
    ) throws {
        let email = approvalEmail.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard Self.isValidEmail(email) else {
            throw WAI3ConfigurationError.invalidApprovalEmail
        }
        guard Self.isValidPrivacyPolicyURL(privacyPolicyURL) else {
            throw WAI3ConfigurationError.invalidPrivacyPolicyURL
        }
        guard Self.isSemanticVersion(compatibilityVersion) else {
            throw WAI3ConfigurationError.invalidCompatibilityVersion
        }

        self.backend = backend
        self.approvalEmail = email
        self.privacyPolicyURL = privacyPolicyURL
        self.compatibilityVersion = compatibilityVersion
    }

    static func fromInfoDictionary(
        _ info: [String: Any]
    ) throws -> WAI3SecureConfiguration {
        guard let rawURL = info["WAISupabaseURL"] as? String,
              let url = URL(string: rawURL),
              let key = info["WAISupabasePublishableKey"] as? String else {
            throw WAI3ConfigurationError.missingBackendConfiguration
        }
        let backend: WAIBackendConfiguration
        do {
            backend = try WAIBackendConfiguration(
                baseURL: url,
                publishableKey: key
            )
        } catch {
            throw WAI3ConfigurationError.missingBackendConfiguration
        }

        guard let approvalEmail = info["WAIApprovalEmail"] as? String else {
            throw WAI3ConfigurationError.invalidApprovalEmail
        }
        guard let rawPrivacyPolicyURL = info["WAIPrivacyPolicyURL"] as? String,
              let privacyPolicyURL = URL(string: rawPrivacyPolicyURL) else {
            throw WAI3ConfigurationError.invalidPrivacyPolicyURL
        }
        let compatibilityVersion =
            info["WAI3CompatibilityVersion"] as? String ?? "3.0"
        return try WAI3SecureConfiguration(
            backend: backend,
            approvalEmail: approvalEmail,
            privacyPolicyURL: privacyPolicyURL,
            compatibilityVersion: compatibilityVersion
        )
    }

    private static func isValidEmail(_ value: String) -> Bool {
        guard (3...254).contains(value.utf8.count),
              !value.contains(where: { $0.isWhitespace }) else {
            return false
        }
        let parts = value.split(
            separator: "@",
            omittingEmptySubsequences: false
        )
        guard parts.count == 2,
              !parts[0].isEmpty,
              !parts[1].isEmpty else {
            return false
        }
        let domainParts = parts[1].split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        return domainParts.count >= 2
        && domainParts.allSatisfy { !$0.isEmpty }
    }

    private static func isSemanticVersion(_ value: String) -> Bool {
        guard (3...32).contains(value.utf8.count) else {
            return false
        }
        let parts = value.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        return (2...3).contains(parts.count)
        && parts.allSatisfy { part in
            (1...9).contains(part.utf8.count)
            && part.utf8.allSatisfy { byte in
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            }
        }
    }

    private static func isValidPrivacyPolicyURL(_ url: URL) -> Bool {
        guard url.absoluteString.utf8.count <= 2_048 else {
            return false
        }
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ), components.scheme == "https",
        components.user == nil,
        components.password == nil,
        components.port == nil,
        components.query == nil,
        components.fragment == nil,
        let host = components.host,
        isValidPublicHostname(host),
        components.path != "/",
        !components.path.isEmpty else {
            return false
        }
        return true
    }

    private static func isValidPublicHostname(_ host: String) -> Bool {
        let normalized = host.lowercased()
        let labels = normalized.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard labels.count >= 2,
              !normalized.hasSuffix(".local"),
              !normalized.hasSuffix(".internal"),
              labels.allSatisfy({ label in
                  (1...63).contains(label.utf8.count)
                  && label.first != "-"
                  && label.last != "-"
                  && label.utf8.allSatisfy { byte in
                      (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                      || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                      || byte == UInt8(ascii: "-")
                  }
              }),
              let topLevelDomain = labels.last,
              topLevelDomain.utf8.contains(where: { byte in
                  (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
              }) else {
            return false
        }
        return true
    }
}

enum WAIApplicationLaunchDecision: Equatable, Sendable {
    case legacy
    case secure(WAI3SecureConfiguration)
    case invalidSecureConfiguration
}

enum WAIApplicationLaunchResolver {
    static func resolve(
        infoDictionary: [String: Any],
        arguments: [String]
    ) -> WAIApplicationLaunchDecision {
        guard secureModeIsEnabled(
            infoDictionary: infoDictionary,
            arguments: arguments
        ) else {
            return .legacy
        }

        do {
            return .secure(
                try WAI3SecureConfiguration.fromInfoDictionary(infoDictionary)
            )
        } catch {
            return .invalidSecureConfiguration
        }
    }

    private static func secureModeIsEnabled(
        infoDictionary: [String: Any],
        arguments: [String]
    ) -> Bool {
        if arguments.contains("--wai3-secure-mode") {
            return true
        }
        if let enabled = infoDictionary["WAI3SecureModeEnabled"] as? Bool {
            return enabled
        }
        if let rawValue = infoDictionary["WAI3SecureModeEnabled"] as? String {
            return ["1", "true", "yes"].contains(rawValue.lowercased())
        }
        return false
    }
}
