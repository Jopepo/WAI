import SwiftUI

@MainActor
struct WAIApplicationRoot: View {
    private enum RootMode {
        case legacy
        case secure(WAI3Runtime)
        case invalidSecureConfiguration
        #if DEBUG
        case approvedUITestFixture(
            WAI3DebugFixtureRuntime,
            WAI3DebugFixturePresentation
        )
        #endif
    }

    private let mode: RootMode

    init(
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:],
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        #if DEBUG
        let darkAccessibilityFixture = arguments.contains(
            WAI3DebugFixturePresentation.darkAccessibilityLaunchArgument
        )
        if arguments.contains("--wai3-approved-ui-test-fixture")
            || darkAccessibilityFixture {
            mode = .approvedUITestFixture(
                WAI3DebugFixtureRuntime(),
                darkAccessibilityFixture ? .darkAccessibility : .standard
            )
            return
        }
        #endif

        let decision = WAIApplicationLaunchResolver.resolve(
            infoDictionary: infoDictionary,
            arguments: arguments
        )

        switch decision {
        case .legacy:
            #if DEBUG || WAI_UPGRADE_TEST_FIXTURE
            if arguments.contains(WAI2UpgradeDebugFixture.launchArgument)
                || ProcessInfo.processInfo.environment[
                    WAI2UpgradeDebugFixture.environmentKey
                ] == "1" {
                do {
                    try WAI2UpgradeDebugFixture.seed()
                } catch {
                    WAI2UpgradeDebugFixture.recordFailure(error)
                    mode = .invalidSecureConfiguration
                    return
                }
            }
            #endif
            mode = .legacy
        case .secure(let configuration):
            do {
                mode = .secure(try WAI3Runtime(configuration: configuration))
            } catch {
                mode = .invalidSecureConfiguration
            }
        case .invalidSecureConfiguration:
            mode = .invalidSecureConfiguration
        }
    }

    var body: some View {
        switch mode {
        case .legacy:
            ContentView()
        case .secure(let runtime):
            WAI3AccessRootView(runtime: runtime)
        case .invalidSecureConfiguration:
            WAI3InvalidConfigurationView()
        #if DEBUG
        case .approvedUITestFixture(let runtime, let presentation):
            WAI3DebugFixtureRootView(
                runtime: runtime,
                presentation: presentation
            )
        #endif
        }
    }
}

private struct WAI3InvalidConfigurationView: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "clock.badge.checkmark")
                    .foregroundStyle(.blue)
                Text("WAI")
                    .font(.headline)
                    .fontWeight(.bold)
                Spacer()
            }
            .padding(.horizontal, 20)
            .frame(height: 56)
            .overlay(alignment: .bottom) { Divider() }

            Spacer()

            VStack(spacing: 14) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(.blue)

                Text("Configuration unavailable")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("This build is not ready for secure access.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)

            Spacer()
        }
        .background(Color(.systemBackground))
    }
}
