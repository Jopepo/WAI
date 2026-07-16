import Foundation
import Testing
@testable import WAI

@MainActor
struct WAIProtectedOperationalDataControllerTests {
    private let userID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let checkedAt = Date(timeIntervalSince1970: 1_784_119_600)

    @Test func offlineApprovalLoadsOnlyValidatedLocalRelease() async throws {
        let fixture = try makeFixture()

        await fixture.controller.prepare(for: access(mode: .offline(.networkUnavailable)))

        #expect(
            fixture.controller.state == .ready(
                WAIProtectedDataReadyState(
                    origin: .bundled,
                    generation: 1,
                    syncState: .offline,
                    checkedAt: nil
                )
            )
        )
        #expect(!fixture.controller.dataService.stations.isEmpty)
        #expect(!fixture.controller.hotelDataService.hotels.isEmpty)
        #expect(!fixture.controller.whatsNewDataService.items.isEmpty)
        #expect(fixture.authentication.validSessionCount == 0)
        #expect(fixture.coordinator.refreshCount == 0)
    }

    @Test func onlineApprovalRefreshesWithFreshSession() async throws {
        let fixture = try makeFixture()
        fixture.coordinator.remoteSelection = OperationalReleaseSelection(
            package: fixture.localSelection.package,
            origin: .remote
        )

        await fixture.controller.prepare(for: access(mode: .online))

        #expect(
            fixture.controller.state == .ready(
                WAIProtectedDataReadyState(
                    origin: .remote,
                    generation: 1,
                    syncState: .current,
                    checkedAt: checkedAt
                )
            )
        )
        #expect(fixture.authentication.validSessionCount == 1)
        #expect(fixture.coordinator.refreshedSession == fixture.authentication.session)
        #expect(fixture.controller.dataService.sourceInfo.kind == .remote)
    }

    @Test func firstOnlineUseCanFetchWithoutBundledFallback() async throws {
        let fixture = try makeFixture()
        fixture.coordinator.localError =
            OperationalReleaseCoordinatorError.noValidatedLocalRelease
        fixture.coordinator.remoteSelection = OperationalReleaseSelection(
            package: fixture.localSelection.package,
            origin: .remote
        )

        await fixture.controller.prepare(for: access(mode: .online))

        #expect(
            fixture.controller.state == .ready(
                WAIProtectedDataReadyState(
                    origin: .remote,
                    generation: 1,
                    syncState: .current,
                    checkedAt: checkedAt
                )
            )
        )
        #expect(fixture.coordinator.refreshCount == 1)
        #expect(fixture.authentication.validSessionCount == 1)
    }

    @Test func firstOfflineUseFailsWithoutValidatedCache() async throws {
        let fixture = try makeFixture()
        fixture.coordinator.localError =
            OperationalReleaseCoordinatorError.noValidatedLocalRelease

        await fixture.controller.prepare(
            for: access(mode: .offline(.networkUnavailable))
        )

        #expect(fixture.controller.state == .failed(.unavailable))
        #expect(fixture.coordinator.refreshCount == 0)
        #expect(fixture.controller.dataService.stations.isEmpty)
    }

    @Test func secureStorageFailureFailsClosedWithoutRemoteRefresh() async throws {
        let fixture = try makeFixture()
        fixture.coordinator.localError =
            OperationalReleaseCoordinatorError.secureStorage

        await fixture.controller.prepare(for: access(mode: .online))

        #expect(fixture.controller.state == .failed(.secureStorage))
        #expect(fixture.coordinator.refreshCount == 0)
        #expect(fixture.authentication.validSessionCount == 0)
        #expect(fixture.controller.dataService.stations.isEmpty)
        #expect(fixture.controller.hotelDataService.hotels.isEmpty)
        #expect(fixture.controller.whatsNewDataService.items.isEmpty)
    }

    @Test func firstOnlineNetworkFailureDoesNotExposeBundledData() async throws {
        let fixture = try makeFixture()
        fixture.coordinator.localError =
            OperationalReleaseCoordinatorError.noValidatedLocalRelease
        fixture.coordinator.refreshError =
            WAIPrivateBackendError.networkUnavailable

        await fixture.controller.prepare(for: access(mode: .online))

        #expect(fixture.controller.state == .failed(.unavailable))
        #expect(fixture.controller.dataService.stations.isEmpty)
        #expect(fixture.controller.hotelDataService.hotels.isEmpty)
    }

    @Test func networkFailureRetainsValidatedBundledData() async throws {
        let fixture = try makeFixture()
        fixture.coordinator.refreshError = WAIPrivateBackendError.networkUnavailable

        await fixture.controller.prepare(for: access(mode: .online))

        #expect(
            fixture.controller.state == .ready(
                WAIProtectedDataReadyState(
                    origin: .bundled,
                    generation: 1,
                    syncState: .refreshDeferred,
                    checkedAt: checkedAt
                )
            )
        )
        #expect(!fixture.controller.dataService.stations.isEmpty)
    }

    @Test func rejectedRemoteReleaseCannotReplaceLocalData() async throws {
        let fixture = try makeFixture()
        fixture.coordinator.refreshError =
            OperationalReleaseValidationError.payloadDigestMismatch(.hotelMap)

        await fixture.controller.prepare(for: access(mode: .online))

        #expect(
            fixture.controller.state == .ready(
                WAIProtectedDataReadyState(
                    origin: .bundled,
                    generation: 1,
                    syncState: .remoteRejected,
                    checkedAt: checkedAt
                )
            )
        )
        #expect(fixture.controller.dataService.sourceInfo.kind == .bundled)
    }

    @Test func forbiddenRemoteAccessClearsInMemoryOperationalData() async throws {
        let fixture = try makeFixture()
        fixture.coordinator.refreshError = WAIPrivateBackendError.forbidden

        await fixture.controller.prepare(for: access(mode: .online))

        #expect(fixture.controller.state == .failed(.authorization))
        #expect(fixture.controller.dataService.stations.isEmpty)
        #expect(fixture.controller.hotelDataService.hotels.isEmpty)
        #expect(fixture.controller.whatsNewDataService.items.isEmpty)
    }

    @Test func explicitResetRemovesAllInMemoryOperationalData() async throws {
        let fixture = try makeFixture()
        await fixture.controller.prepare(for: access(mode: .offline(.sessionUnavailable)))

        fixture.controller.reset()

        #expect(fixture.controller.state == .idle)
        #expect(fixture.controller.dataService.stations.isEmpty)
        #expect(fixture.controller.hotelDataService.hotels.isEmpty)
        #expect(fixture.controller.whatsNewDataService.items.isEmpty)
    }

    @Test func protectedServicesCannotInvokeLegacyRemoteRefresh() async throws {
        let fixture = try makeFixture()

        let transport = await fixture.controller.dataService.refreshRemoteData()
        let hotels = await fixture.controller.hotelDataService.refreshRemoteData()
        let whatsNew = await fixture.controller.whatsNewDataService.refreshRemoteData()

        #expect(!transport)
        #expect(!hotels)
        #expect(!whatsNew)
    }

    @Test func protectedReleaseFeedsTheManualCalculator() async throws {
        let fixture = try makeFixture()
        fixture.coordinator.remoteSelection = OperationalReleaseSelection(
            package: fixture.localSelection.package,
            origin: .remote
        )

        await fixture.controller.prepare(for: access(mode: .online))

        #expect(fixture.controller.dataService.sourceInfo.kind == .remote)
        let cph = try #require(
            fixture.controller.dataService.stations.first {
                $0.iata == "CPH"
            }
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let etdDate = try #require(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 7,
            day: 7,
            hour: 12
        )))
        let result = try #require(TimeCalculator.calculate(
            selectedHour: 8,
            selectedMinute: 0,
            station: cph,
            selectedAlternative: "__DEFAULT__",
            defaultAlternativeTag: "__DEFAULT__",
            inputReference: .utc,
            etdDate: etdDate,
            stationHolidays: cph.holidays ?? []
        ))

        #expect(result.transportTime == "35 min")
        #expect(result.pickup == "08:25 CPH (07:25 LIS)")
        #expect(result.wakeup == "07:25 CPH (06:25 LIS)")
        #expect(fixture.coordinator.refreshCount == 1)
    }

    private func makeFixture() throws -> ProtectedDataFixture {
        let package = try BundledOperationalReleaseProvider(bundle: .main).load()
        let localSelection = OperationalReleaseSelection(
            package: package,
            origin: .bundled
        )
        let coordinator = StubOperationalReleaseCoordinator(
            localSelection: localSelection
        )
        let authentication = StubProtectedDataAuthenticationService(
            session: session()
        )
        let controller = WAIProtectedOperationalDataController(
            authenticationService: authentication,
            releaseCoordinator: coordinator,
            now: { checkedAt }
        )
        return ProtectedDataFixture(
            controller: controller,
            authentication: authentication,
            coordinator: coordinator,
            localSelection: localSelection
        )
    }

    private func access(mode: WAIAccessMode) -> WAIApprovedAccess {
        WAIApprovedAccess(
            userID: userID,
            mode: mode,
            lastVerifiedAt: checkedAt.addingTimeInterval(-60)
        )
    }

    private func session() -> WAIAuthSession {
        WAIAuthSession(
            userID: userID,
            accessToken: "access-token",
            refreshToken: "refresh-token",
            expiresAt: checkedAt.addingTimeInterval(3_600)
        )
    }
}

@MainActor
private struct ProtectedDataFixture {
    let controller: WAIProtectedOperationalDataController
    let authentication: StubProtectedDataAuthenticationService
    let coordinator: StubOperationalReleaseCoordinator
    let localSelection: OperationalReleaseSelection
}

private final class StubOperationalReleaseCoordinator: OperationalReleaseCoordinating {
    let localSelection: OperationalReleaseSelection
    var localError: Error?
    var remoteSelection: OperationalReleaseSelection?
    var refreshError: Error?
    private(set) var refreshCount = 0
    private(set) var refreshedSession: WAIAuthSession?

    init(localSelection: OperationalReleaseSelection) {
        self.localSelection = localSelection
    }

    func loadBestAvailable(
        for userID: UUID
    ) async throws -> OperationalReleaseSelection {
        if let localError {
            throw localError
        }
        return localSelection
    }

    func refresh(
        for session: WAIAuthSession,
        refreshToken: OperationalReleaseRefreshToken
    ) async throws -> OperationalReleaseSelection {
        refreshCount += 1
        refreshedSession = session
        if let refreshError {
            throw refreshError
        }
        guard let remoteSelection else {
            throw WAIPrivateBackendError.notFound
        }
        return remoteSelection
    }
}

private final class StubProtectedDataAuthenticationService: WAIAuthenticationServicing {
    let session: WAIAuthSession
    var validSessionError: Error?
    private(set) var validSessionCount = 0

    init(session: WAIAuthSession) {
        self.session = session
    }

    func restoreSession() async throws -> WAIAuthSession? {
        session
    }

    func validSession() async throws -> WAIAuthSession {
        validSessionCount += 1
        if let validSessionError {
            throw validSessionError
        }
        return session
    }

    func signInWithApple(
        credential: WAIAppleSignInCredential
    ) async throws -> WAIAuthSession {
        session
    }

    func fetchProfile(for session: WAIAuthSession) async throws -> WAIUserProfile {
        throw WAIAuthenticationServiceError.invalidResponse
    }

    func deleteAccount(
        credential: WAIAppleSignInCredential,
        expectedUserID: UUID
    ) async throws {}

    func signOut(session: WAIAuthSession?) async throws {}
}
