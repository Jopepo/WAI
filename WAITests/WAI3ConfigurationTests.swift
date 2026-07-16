import Foundation
import Testing
@testable import WAI

struct WAI3ConfigurationTests {
    @Test func currentBuildRemainsOnLegacyLaunchPath() {
        let decision = WAIApplicationLaunchResolver.resolve(
            infoDictionary: Bundle.main.infoDictionary ?? [:],
            arguments: []
        )

        #expect(decision == .legacy)
    }

    @Test func secureModeWithoutCompleteConfigurationFailsClosed() {
        let decision = WAIApplicationLaunchResolver.resolve(
            infoDictionary: [:],
            arguments: ["--wai3-secure-mode"]
        )

        #expect(decision == .invalidSecureConfiguration)
    }

    @Test func completeSecureConfigurationCanBeEnabledExplicitly() throws {
        let info = validInfoDictionary()
        let expected = try WAI3SecureConfiguration.fromInfoDictionary(info)

        let decision = WAIApplicationLaunchResolver.resolve(
            infoDictionary: info,
            arguments: []
        )

        #expect(decision == .secure(expected))
        #expect(expected.compatibilityVersion == "3.0")
        #expect(
            expected.privacyPolicyURL.absoluteString
            == "https://www.example.com/wai/privacy"
        )
    }

    @Test func configurationDoesNotActivateWithoutFeatureFlag() {
        var info = validInfoDictionary()
        info["WAI3SecureModeEnabled"] = false

        #expect(
            WAIApplicationLaunchResolver.resolve(
                infoDictionary: info,
                arguments: []
            ) == .legacy
        )
    }

    @Test func malformedBackendOrApprovalAddressIsRejected() {
        var invalidHost = validInfoDictionary()
        invalidHost["WAISupabaseURL"] = "https://raw.githubusercontent.com"
        #expect(
            WAIApplicationLaunchResolver.resolve(
                infoDictionary: invalidHost,
                arguments: []
            ) == .invalidSecureConfiguration
        )

        var invalidEmail = validInfoDictionary()
        invalidEmail["WAIApprovalEmail"] = "not-an-email"
        #expect(
            WAIApplicationLaunchResolver.resolve(
                infoDictionary: invalidEmail,
                arguments: []
            ) == .invalidSecureConfiguration
        )
    }

    @Test func invalidCompatibilityVersionIsRejected() {
        var info = validInfoDictionary()
        info["WAI3CompatibilityVersion"] = "latest"

        #expect(
            WAIApplicationLaunchResolver.resolve(
                infoDictionary: info,
                arguments: []
            ) == .invalidSecureConfiguration
        )
    }

    @Test func oversizedPublicConfigurationValuesAreRejected() {
        var email = validInfoDictionary()
        email["WAIApprovalEmail"] = String(repeating: "a", count: 250)
            + "@example.com"
        #expect(
            WAIApplicationLaunchResolver.resolve(
                infoDictionary: email,
                arguments: []
            ) == .invalidSecureConfiguration
        )

        var version = validInfoDictionary()
        version["WAI3CompatibilityVersion"] = "3."
            + String(repeating: "1", count: 30)
        #expect(
            WAIApplicationLaunchResolver.resolve(
                infoDictionary: version,
                arguments: []
            ) == .invalidSecureConfiguration
        )

        var key = validInfoDictionary()
        key["WAISupabasePublishableKey"] = "sb_publishable_"
            + String(repeating: "x", count: 512)
        #expect(
            WAIApplicationLaunchResolver.resolve(
                infoDictionary: key,
                arguments: []
            ) == .invalidSecureConfiguration
        )
    }

    @Test(arguments: [
        nil,
        "http://example.com/privacy",
        "https://example.com/",
        "https://example.com/privacy?token=secret",
        "https://127.0.0.1/privacy",
        "https://privacy.internal/policy"
    ])
    func missingOrUnsafePrivacyPolicyURLIsRejected(
        value: String?
    ) {
        var missing = validInfoDictionary()
        missing["WAIPrivacyPolicyURL"] = value
        #expect(
            WAIApplicationLaunchResolver.resolve(
                infoDictionary: missing,
                arguments: []
            ) == .invalidSecureConfiguration
        )
    }

    private func validInfoDictionary() -> [String: Any] {
        [
            "WAI3SecureModeEnabled": true,
            "WAISupabaseURL": "https://abcdefghijklmnopqrst.supabase.co",
            "WAISupabasePublishableKey": "sb_publishable_1234567890abcdef",
            "WAIApprovalEmail": "approval@example.com",
            "WAIPrivacyPolicyURL": "https://www.example.com/wai/privacy"
        ]
    }
}
