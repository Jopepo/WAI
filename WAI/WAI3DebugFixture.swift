#if DEBUG
import Foundation
import SwiftUI

enum WAI3DebugFixturePresentation {
    case standard
    case darkAccessibility

    static let darkAccessibilityLaunchArgument =
        "--wai3-approved-ui-test-fixture-dark-accessibility"
}

@MainActor
final class WAI3DebugFixtureRuntime {
    let rosterController: WAIRosterController
    let roomNumberController: WAIRoomNumberController
    let calculationHistoryStore: CalculationHistoryStore
    let hotelStayStore: HotelStayStore
    let dataService: DataService
    let hotelDataService: HotelDataService
    let whatsNewDataService: WhatsNewDataService

    init(now: Date = Date(timeIntervalSince1970: 1_784_147_400)) {
        let ownerUserID = UUID(
            uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        ) ?? UUID()
        let archive = Self.makeArchive(now: now)
        let rosterController = WAIRosterController(
            store: WAI3DebugRosterStore(archive: archive),
            calendarSource: WAI3DebugCalendarSource(),
            now: { now }
        )
        let roomNumberController = WAIRoomNumberController(
            store: WAI3DebugRoomNumberStore(ownerUserID: ownerUserID),
            now: { now }
        )
        let calculationHistoryStore = CalculationHistoryStore(
            persistence: WAI3DebugCalculationPersistence()
        )
        let hotelStayStore = HotelStayStore(
            persistence: WAI3DebugHotelStayPersistence()
        )

        self.rosterController = rosterController
        self.roomNumberController = roomNumberController
        self.calculationHistoryStore = calculationHistoryStore
        self.hotelStayStore = hotelStayStore
        dataService = Self.makeDataService(now: now)
        hotelDataService = Self.makeHotelDataService(now: now)
        whatsNewDataService = Self.makeWhatsNewDataService(now: now)

        rosterController.prepare(for: ownerUserID)
        roomNumberController.prepare(for: ownerUserID)
        calculationHistoryStore.prepare(for: ownerUserID)
        hotelStayStore.prepare(for: ownerUserID)
    }

    private static func makeArchive(now: Date) -> RosterArchive {
        let outboundDutyStart = now.addingTimeInterval(-8 * 3_600)
        let outboundDeparture = now.addingTimeInterval(-7 * 3_600)
        let outboundArrival = now.addingTimeInterval(-4 * 3_600)
        let outboundDutyEnd = now.addingTimeInterval(-3.5 * 3_600)
        let inboundDutyStart = now.addingTimeInterval(5 * 3_600)
        let inboundDeparture = now.addingTimeInterval(6 * 3_600)
        let inboundArrival = now.addingTimeInterval(9 * 3_600)
        let inboundDutyEnd = now.addingTimeInterval(9.5 * 3_600)
        let reviewDutyStart = now.addingTimeInterval(9 * 3_600)
        let reviewDeparture = now.addingTimeInterval(10 * 3_600)
        let reviewArrival = now.addingTimeInterval(11.5 * 3_600)
        let reviewDutyEnd = now.addingTimeInterval(12 * 3_600)

        let outboundLeg = RosterLeg(
            id: "fixture-outbound-leg",
            flightNumber: "TP0754",
            departure: localDateTime(
                outboundDeparture,
                timeZoneIdentifier: "Europe/Lisbon"
            ),
            arrival: localDateTime(
                outboundArrival,
                timeZoneIdentifier: "Europe/Copenhagen"
            ),
            originIATA: "LIS",
            originName: "Lisbon",
            destinationIATA: "CPH",
            destinationName: "Copenhagen",
            aircraftRegistration: "CS-TVA",
            aircraftName: "Airbus A320neo",
            passengerLoad: "154",
            cosmicRadiation: 1.2,
            crew: fixtureCrew
        )
        let inboundLeg = RosterLeg(
            id: "fixture-inbound-leg",
            flightNumber: "TP0755",
            departure: localDateTime(
                inboundDeparture,
                timeZoneIdentifier: "Europe/Copenhagen"
            ),
            arrival: localDateTime(
                inboundArrival,
                timeZoneIdentifier: "Europe/Lisbon"
            ),
            originIATA: "CPH",
            originName: "Copenhagen",
            destinationIATA: "LIS",
            destinationName: "Lisbon",
            aircraftRegistration: "CS-TVB",
            aircraftName: "Airbus A320neo",
            passengerLoad: "148",
            cosmicRadiation: 1.1,
            crew: fixtureCrew
        )
        let reviewLeg = RosterLeg(
            id: "fixture-review-leg",
            flightNumber: "TP0999",
            departure: localDateTime(
                reviewDeparture,
                timeZoneIdentifier: "Europe/Lisbon"
            ),
            arrival: unresolvedLocalDateTime(
                reviewArrival,
                displayTimeZoneIdentifier: "Europe/Moscow"
            ),
            originIATA: "LIS",
            originName: "Lisbon",
            destinationIATA: "DME",
            destinationName: "Moscow",
            aircraftRegistration: nil,
            aircraftName: nil,
            passengerLoad: nil,
            cosmicRadiation: nil,
            crew: fixtureCrew
        )
        let outboundDuty = RosterDuty(
            id: "fixture-outbound-duty",
            activityCode: "2CPH1501P",
            start: outboundDutyStart,
            end: outboundDutyEnd,
            timeZoneIdentifier: "Europe/Lisbon",
            kind: .flight,
            hotelCode: "CPHRDS",
            legs: [outboundLeg]
        )
        let inboundDuty = RosterDuty(
            id: "fixture-inbound-duty",
            activityCode: "CPHLIS",
            start: inboundDutyStart,
            end: inboundDutyEnd,
            timeZoneIdentifier: "Europe/Copenhagen",
            kind: .flight,
            hotelCode: nil,
            legs: [inboundLeg]
        )
        let reviewDuty = RosterDuty(
            id: "fixture-review-duty",
            activityCode: "LISDME",
            start: reviewDutyStart,
            end: reviewDutyEnd,
            timeZoneIdentifier: "Europe/Lisbon",
            kind: .flight,
            hotelCode: nil,
            legs: [reviewLeg]
        )
        let document = RosterDocument(
            source: RosterSource(
                company: .tap,
                productIdentifier: "-//TAP Portal DOV UI Test//EN",
                calendarName: "Escala TAP UI Test",
                crewIdentifier: "12345.6",
                sourceName: "Local UI test fixture",
                sha256: String(repeating: "a", count: 64),
                importedAt: now
            ),
            coverage: RosterCoveragePeriod(
                start: now.addingTimeInterval(-24 * 3_600),
                end: now.addingTimeInterval(48 * 3_600),
                timeZoneIdentifier: "Europe/Lisbon"
            ),
            duties: [outboundDuty, inboundDuty, reviewDuty]
        )
        return RosterArchive(
            segments: [
                RosterImportSegment(
                    document: document,
                    issues: [
                        RosterImportIssue(
                            code: .unresolvedStationTimeZone,
                            dutyID: reviewDuty.id,
                            flightNumber: reviewLeg.flightNumber,
                            stationIATA: "DME"
                        )
                    ]
                )
            ]
        )
    }

    private static func makeDataService(now: Date) -> DataService {
        let service = DataService(mode: .protectedRelease)
        service.applyProtected(
            document: StationData(
                source: fixtureSource,
                stations: [
                    Station(
                        iata: "CPH",
                        icao: "EKCH",
                        city: "Copenhagen",
                        country: "Denmark",
                        timeZone: "Europe/Copenhagen",
                        standardUtcOffset: "+01:00",
                        summerUtcOffset: "+02:00",
                        defaultRule: TransportRule(
                            type: "fixed",
                            label: "Standard transfer",
                            transportMinutes: 30,
                            minTransportMinutes: nil,
                            maxTransportMinutes: nil,
                            rules: nil,
                            conditions: nil
                        ),
                        alternatives: [],
                        holidays: []
                    )
                ]
            ),
            sourceInfo: fixtureSourceInfo(now: now)
        )
        return service
    }

    private static func makeHotelDataService(now: Date) -> HotelDataService {
        let service = HotelDataService(mode: .protectedRelease)
        service.applyProtected(
            document: HotelDocument(
                document: "Local UI test fixture",
                revision: "DEBUG1",
                date: "2026-07-15",
                hotels: [
                    Hotel(
                        iata: "CPH",
                        icao: "EKCH",
                        city: "Copenhagen",
                        country: "Denmark",
                        name: "RADISSON BLU SCANDINAVIA HOTEL",
                        phone: nil,
                        email: nil,
                        fax: nil
                    )
                ]
            ),
            sourceInfo: fixtureSourceInfo(now: now)
        )
        return service
    }

    private static func makeWhatsNewDataService(now: Date) -> WhatsNewDataService {
        let service = WhatsNewDataService(mode: .protectedRelease)
        service.applyProtected(
            document: WhatsNewDocument(
                source: fixtureSource,
                maxVisibleItems: 1,
                items: [
                    WhatsNewItem(
                        id: "debug-fixture",
                        title: "Local test data",
                        detail: "Available only in the DEBUG UI test fixture.",
                        priority: .low,
                        category: .app,
                        documentRevision: "DEBUG1"
                    )
                ]
            ),
            sourceInfo: fixtureSourceInfo(now: now)
        )
        return service
    }

    private static func localDateTime(
        _ date: Date,
        timeZoneIdentifier: String
    ) -> RosterLocalDateTime {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)
            ?? TimeZone(secondsFromGMT: 0)
            ?? .current
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: date
        )
        return RosterLocalDateTime(
            year: components.year ?? 1970,
            month: components.month ?? 1,
            day: components.day ?? 1,
            hour: components.hour ?? 0,
            minute: components.minute ?? 0,
            timeZoneIdentifier: timeZoneIdentifier,
            instant: calendar.date(from: components)
        )
    }

    private static func unresolvedLocalDateTime(
        _ date: Date,
        displayTimeZoneIdentifier: String
    ) -> RosterLocalDateTime {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(
            identifier: displayTimeZoneIdentifier
        ) ?? .gmt
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: date
        )
        return RosterLocalDateTime(
            year: components.year ?? 1970,
            month: components.month ?? 1,
            day: components.day ?? 1,
            hour: components.hour ?? 0,
            minute: components.minute ?? 0,
            timeZoneIdentifier: nil,
            instant: nil
        )
    }

    private static func fixtureSourceInfo(
        now: Date
    ) -> OperationalDataSourceInfo {
        OperationalDataSourceInfo(
            kind: .cached,
            document: fixtureSource.document,
            revision: fixtureSource.revision,
            date: fixtureSource.date,
            loadedAt: now
        )
    }

    private static let fixtureSource = OperationalDataDocumentSource(
        document: "Local UI test fixture",
        revision: "DEBUG1",
        date: "2026-07-15"
    )

    private static let fixtureCrew = [
        RosterCrewMember(
            employeeIdentifier: "10000.1",
            roleCode: "CPT",
            name: "Test Captain",
            isDeadhead: false
        ),
        RosterCrewMember(
            employeeIdentifier: "12345.6",
            roleCode: "CAB",
            name: "Test Crew Member",
            isDeadhead: false
        )
    ]
}

@MainActor
struct WAI3DebugFixtureRootView: View {
    @StateObject private var rosterController: WAIRosterController
    @StateObject private var roomNumberController: WAIRoomNumberController
    @StateObject private var calculationHistoryStore: CalculationHistoryStore
    @StateObject private var hotelStayStore: HotelStayStore
    private let dataService: DataService
    private let hotelDataService: HotelDataService
    private let whatsNewDataService: WhatsNewDataService
    private let presentation: WAI3DebugFixturePresentation

    init(
        runtime: WAI3DebugFixtureRuntime,
        presentation: WAI3DebugFixturePresentation = .standard
    ) {
        _rosterController = StateObject(
            wrappedValue: runtime.rosterController
        )
        _roomNumberController = StateObject(
            wrappedValue: runtime.roomNumberController
        )
        _calculationHistoryStore = StateObject(
            wrappedValue: runtime.calculationHistoryStore
        )
        _hotelStayStore = StateObject(
            wrappedValue: runtime.hotelStayStore
        )
        dataService = runtime.dataService
        hotelDataService = runtime.hotelDataService
        whatsNewDataService = runtime.whatsNewDataService
        self.presentation = presentation
    }

    @ViewBuilder
    var body: some View {
        if presentation == .darkAccessibility {
            workspace
                .preferredColorScheme(.dark)
                .dynamicTypeSize(.accessibility5)
        } else {
            workspace
        }
    }

    private var workspace: some View {
        WAI3CrewWorkspaceView(
            rosterController: rosterController,
            roomNumberController: roomNumberController,
            calculationHistoryStore: calculationHistoryStore,
            hotelStayStore: hotelStayStore,
            dataService: dataService,
            hotelDataService: hotelDataService,
            whatsNewDataService: whatsNewDataService,
            accountAction: {}
        )
        .accessibilityIdentifier("wai3.approvedUITestFixture")
    }
}

private final class WAI3DebugRosterStore: RosterArchiveStoring {
    private var archive: RosterArchive

    init(archive: RosterArchive) {
        self.archive = archive
    }

    func load(for ownerUserID: UUID) throws -> RosterArchive? {
        archive
    }

    func save(_ archive: RosterArchive, for ownerUserID: UUID) throws {
        self.archive = archive
    }

    func clear() throws {
        archive = RosterArchive()
    }
}

@MainActor
private final class WAI3DebugCalendarSource: WAIRosterCalendarSourcing {
    var authorization: WAIRosterCalendarAuthorization {
        .notDetermined
    }

    func requestFullAccess() async throws -> WAIRosterCalendarAuthorization {
        .denied
    }

    func candidates(
        referenceDate: Date
    ) throws -> [WAIRosterCalendarCandidate] {
        []
    }
}

private final class WAI3DebugRoomNumberStore: RosterRoomNumberStoring {
    private let ownerUserID: UUID
    private var records: [RosterRoomNumberRecord] = []

    init(ownerUserID: UUID) {
        self.ownerUserID = ownerUserID
    }

    func load(for ownerUserID: UUID) throws -> [RosterRoomNumberRecord] {
        guard ownerUserID == self.ownerUserID else {
            throw ProtectedRoomNumberStoreError.ownerMismatch
        }
        return records
    }

    func save(
        _ records: [RosterRoomNumberRecord],
        for ownerUserID: UUID
    ) throws {
        guard ownerUserID == self.ownerUserID else {
            throw ProtectedRoomNumberStoreError.ownerMismatch
        }
        self.records = records
    }

    func clear() throws {
        records = []
    }
}

private final class WAI3DebugCalculationPersistence:
    CalculationHistoryPersisting
{
    let requiresOwner = true
    private var snapshot = CalculationHistorySnapshot.empty

    func load(for ownerUserID: UUID?) throws -> CalculationHistorySnapshot {
        guard ownerUserID != nil else {
            throw ProtectedManualDataStoreError.ownerMismatch
        }
        return snapshot
    }

    func save(
        _ snapshot: CalculationHistorySnapshot,
        for ownerUserID: UUID?
    ) throws {
        guard ownerUserID != nil else {
            throw ProtectedManualDataStoreError.ownerMismatch
        }
        self.snapshot = snapshot
    }

    func clear() throws {
        snapshot = .empty
    }
}

private final class WAI3DebugHotelStayPersistence: HotelStayPersisting {
    let requiresOwner = true
    private var snapshot = HotelStaySnapshot.empty

    func load(for ownerUserID: UUID?) throws -> HotelStaySnapshot {
        guard ownerUserID != nil else {
            throw ProtectedManualDataStoreError.ownerMismatch
        }
        return snapshot
    }

    func save(
        _ snapshot: HotelStaySnapshot,
        for ownerUserID: UUID?
    ) throws {
        guard ownerUserID != nil else {
            throw ProtectedManualDataStoreError.ownerMismatch
        }
        self.snapshot = snapshot
    }

    func clear() throws {
        snapshot = .empty
    }
}
#endif
