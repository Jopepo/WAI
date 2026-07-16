import Foundation

@MainActor
final class WAI3Runtime {
    let configuration: WAI3SecureConfiguration
    let authenticationService: SupabaseWAIAuthenticationService
    let accessController: WAIAccessController
    let operationalDataController: WAIProtectedOperationalDataController
    let rosterController: WAIRosterController
    let roomNumberController: WAIRoomNumberController
    let personalizationController: WAIRosterPersonalizationController
    let calculationHistoryStore: CalculationHistoryStore
    let hotelStayStore: HotelStayStore

    init(configuration: WAI3SecureConfiguration) throws {
        try WAI3LegacyDataSanitizer.production().sanitize()
        self.configuration = configuration

        let backendClient = SupabaseWAIBackendClient(
            configuration: configuration.backend
        )
        let authenticationService = SupabaseWAIAuthenticationService(
            authBackend: SupabaseAuthSessionBackend(
                configuration: configuration.backend
            ),
            profileService: backendClient,
            accountDeletionService: SupabaseWAIAccountDeletionClient(
                configuration: configuration.backend
            )
        )
        let releaseAccessFence = OperationalReleaseAccessFence()
        let protectedCache = try ProtectedOperationalReleaseCache.production(
            accessFence: releaseAccessFence
        )
        let rosterStore = try ProtectedRosterStore.production()
        let roomNumberStore = KeychainRosterRoomNumberStore()
        let personalizationStore =
            try ProtectedRosterPersonalizationStore.production()
        let calculationHistoryPersistence =
            try ProtectedCalculationHistoryPersistence.production()
        let hotelStayPersistence = try ProtectedHotelStayPersistence.production()
        let releaseCoordinator = OperationalReleaseCoordinator(
            remote: backendClient,
            cache: protectedCache,
            currentAppVersion: configuration.compatibilityVersion
        )

        self.authenticationService = authenticationService
        calculationHistoryStore = CalculationHistoryStore(
            persistence: calculationHistoryPersistence
        )
        hotelStayStore = HotelStayStore(
            persistence: hotelStayPersistence
        )
        accessController = WAIAccessController(
            authenticationService: authenticationService,
            approvalStore: KeychainWAIOfflineApprovalStore(),
            sensitiveDataStore: WAISensitiveDataStoreGroup([
                protectedCache,
                rosterStore,
                roomNumberStore,
                personalizationStore,
                calculationHistoryPersistence,
                hotelStayPersistence,
                UserDefaultsCalculationHistoryPersistence(),
                UserDefaultsHotelStayPersistence()
            ])
        )
        operationalDataController = WAIProtectedOperationalDataController(
            authenticationService: authenticationService,
            releaseCoordinator: releaseCoordinator,
            releaseAccessFence: releaseAccessFence
        )
        rosterController = WAIRosterController(
            store: rosterStore,
            calendarSource: EventKitRosterCalendarSource()
        )
        roomNumberController = WAIRoomNumberController(
            store: roomNumberStore
        )
        personalizationController = WAIRosterPersonalizationController(
            store: personalizationStore
        )
    }
}
