import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
struct WAI3CrewWorkspaceView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var rosterController: WAIRosterController
    @ObservedObject var roomNumberController: WAIRoomNumberController
    @ObservedObject var personalizationController:
        WAIRosterPersonalizationController
    @ObservedObject var calculationHistoryStore: CalculationHistoryStore
    @ObservedObject var hotelStayStore: HotelStayStore
    let dataService: DataService
    let hotelDataService: HotelDataService
    let whatsNewDataService: WhatsNewDataService
    let accountAction: () -> Void

    @State private var showingFileImporter = false
    @State private var showingHomeRoutineSettings = false
    @State private var selectedDuty: WAI3DutySelection?
    @State private var selectedHotel: Hotel?
    @State private var selectedRoutineEditor: WAI3RoutineEditorSelection?
    @State private var todayScrollRequest = 0

    var body: some View {
        TabView {
            NavigationStack {
                rosterContent
                    .navigationTitle("Roster")
                    .toolbar {
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            Button {
                                todayScrollRequest += 1
                            } label: {
                                Image(systemName: "calendar")
                            }
                            .accessibilityLabel("Go to today")
                            .accessibilityIdentifier("wai3.roster.today")

                            Button(action: connectCalendar) {
                                if isRefreshingCalendar {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                            }
                            .disabled(isRefreshingCalendar)
                            .accessibilityLabel("Refresh roster from Calendar")
                            .accessibilityIdentifier("wai3.roster.refresh")

                            Button(action: accountAction) {
                                Image(systemName: "person.crop.circle")
                            }
                            .accessibilityLabel("Account")
                        }
                    }
            }
            .tabItem {
                Label("Roster", systemImage: "calendar")
            }

            WAI3RosterAnalysisView(
                rosterController: rosterController,
                refreshCalendarAction: connectCalendar,
                importRosterAction: { showingFileImporter = true }
            )
                .tabItem {
                    Label("Analysis", systemImage: "chart.bar.xaxis")
                }

            ContentView(
                dataService: dataService,
                hotelDataService: hotelDataService,
                whatsNewDataService: whatsNewDataService,
                allowsLegacyRemoteRefresh: false,
                historyStore: calculationHistoryStore,
                hotelStayStore: hotelStayStore,
                accountAction: accountAction
            )
            .tabItem {
                Label("Calculator", systemImage: "clock")
            }
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [Self.iCalendarType]
        ) { result in
            switch result {
            case .success(let url):
                Task {
                    await rosterController.importFile(
                        at: url,
                        stationTimeZones: stationTimeZones
                    )
                }
            case .failure:
                break
            }
        }
        .sheet(item: $selectedDuty) { selection in
            WAI3DutyDetailView(
                duty: selection.duty,
                stay: selection.stay,
                analysis: selection.analysis,
                stations: dataService.stations,
                hotel: selection.stay.flatMap {
                    hotelDataService.hotel(for: $0.stationIATA)
                },
                rosterController: rosterController,
                roomNumberController: roomNumberController,
                personalizationController: personalizationController,
                hotelStayStore: hotelStayStore
            )
        }
        .sheet(item: $selectedHotel) { hotel in
            HotelDetailView(
                hotel: hotel,
                hotelStayStore: hotelStayStore
            )
        }
        .sheet(item: $selectedRoutineEditor) { selection in
            WAI3RoutineEditorSheet(
                selection: selection,
                controller: personalizationController
            )
        }
        .sheet(isPresented: $showingHomeRoutineSettings) {
            WAI3HomeRoutineSettingsView(
                stations: dataService.stations,
                controller: personalizationController,
                suggestedBaseIATA: nil
            )
        }
        .alert(
            "Roster not imported",
            isPresented: Binding(
                get: { rosterController.importFailure != nil },
                set: { isPresented in
                    if !isPresented {
                        rosterController.clearImportFailure()
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                rosterController.clearImportFailure()
            }
        } message: {
            Text(importFailureMessage)
        }
        .task {
            await rosterController.refreshCalendarIfAuthorized(
                stationTimeZones: stationTimeZones
            )
        }
        .onChange(of: scenePhase) {
            guard scenePhase == .active else {
                return
            }
            Task {
                await rosterController.refreshCalendarIfAuthorized(
                    stationTimeZones: stationTimeZones,
                    force: true
                )
            }
        }
    }

    private var isRefreshingCalendar: Bool {
        switch rosterController.calendarState {
        case .requestingAccess, .scanning:
            true
        case .notDetermined, .available, .accessDenied, .restricted,
             .noRosterFound, .selectionRequired, .synced, .failed:
            false
        }
    }

    @ViewBuilder
    private var rosterContent: some View {
        switch rosterController.state {
        case .idle, .loading:
            ProgressView("Loading roster")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failedSecureStorage:
            ContentUnavailableView(
                "Roster unavailable",
                systemImage: "lock.trianglebadge.exclamationmark",
                description: Text("Protected local storage could not be opened.")
            )
        case .ready(let archive):
            archiveContent(archive, isImporting: false)
        case .importing(let archive):
            archiveContent(archive, isImporting: true)
        }
    }

    @ViewBuilder
    private func archiveContent(
        _ archive: RosterArchive,
        isImporting: Bool
    ) -> some View {
        let staysByDuty = Dictionary(
            uniqueKeysWithValues: RosterTimelineBuilder.stays(
                duties: archive.duties,
                stations: dataService.stations,
                hotels: hotelDataService.hotels
            ).map { ($0.arrivalDutyID, $0) }
        )
        let analysesByDuty = Dictionary(
            uniqueKeysWithValues: RosterDutyAnalyzer.analyze(
                archive.duties
            ).map { ($0.dutyID, $0) }
        )

        if archive.duties.isEmpty {
            WAI3EmptyRosterView(
                isImporting: isImporting,
                calendarState: rosterController.calendarState,
                connectAction: connectCalendar,
                selectAction: selectCalendar,
                settingsAction: openCalendarSettings,
                importAction: { showingFileImporter = true }
            )
        } else {
            ScrollViewReader { proxy in
                List {
                    if isImporting {
                        Section {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text(
                                    rosterController.calendarState == .scanning
                                        ? "Checking Calendar"
                                        : "Importing roster"
                                )
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    calendarStatusSection

                    homeRoutineStatusSection

                    if !archive.issues.isEmpty {
                        Section {
                            Label(
                                "Some airport times need verification",
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                        }
                    }

                    ForEach(groupedDuties(archive.duties), id: \.dateKey) { group in
                        Section(group.title) {
                            ForEach(group.duties) { duty in
                                let stay = staysByDuty[duty.id]
                                let hotel = stay.flatMap {
                                    hotelDataService.hotel(for: $0.stationIATA)
                                }
                                let analysis = analysesByDuty[duty.id]
                                let homeRoutine = RosterHomeRoutineBuilder.routine(
                                    for: duty,
                                    settings: personalizationController.homeRoutine,
                                    override: personalizationController
                                        .homeRoutineOverride(for: duty.id)
                                )
                                let stayOverride = stay.flatMap {
                                    personalizationController
                                        .stayRoutineOverride(for: $0.id)
                                }
                                WAI3DutyRow(
                                    duty: duty,
                                    stay: stay,
                                    analysis: analysis,
                                    homeRoutine: homeRoutine,
                                    showsHomeRoutineSetup:
                                        personalizationController.homeRoutine == nil
                                        && personalizationController.state
                                            != .failedSecureStorage
                                        && duty.kind == .flight,
                                    roomNumber: stay.flatMap {
                                        roomNumberController.roomNumber(for: $0.id)
                                    },
                                    stayRoutineOverride: stayOverride,
                                    openDuty: {
                                        selectedDuty = WAI3DutySelection(
                                            duty: duty,
                                            stay: stay,
                                            analysis: analysis
                                        )
                                    },
                                    openHotel: hotel.map { hotel in
                                        { selectedHotel = hotel }
                                    },
                                    editHomeRoutine: {
                                        if let homeRoutine {
                                            selectedRoutineEditor = .home(homeRoutine)
                                        } else {
                                            showingHomeRoutineSettings = true
                                        }
                                    },
                                    editStayRoutine: { details in
                                        guard let stay else { return }
                                        selectedRoutineEditor = .stay(
                                            stay: stay,
                                            details: details,
                                            override: stayOverride
                                        )
                                    }
                                )
                                .id(duty.id)
                            }
                        }
                    }

                }
                .listStyle(.insetGrouped)
                .task(id: archiveScrollIdentifier(archive)) {
                    await Task.yield()
                    if let dutyID = initialDutyID(
                        in: archive,
                        stays: Array(staysByDuty.values)
                    ) {
                        proxy.scrollTo(dutyID, anchor: .top)
                    }
                }
                .onChange(of: todayScrollRequest) {
                    guard let dutyID = initialDutyID(
                        in: archive,
                        stays: Array(staysByDuty.values)
                    ) else {
                        return
                    }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(dutyID, anchor: .top)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var homeRoutineStatusSection: some View {
        if personalizationController.state == .failedSecureStorage {
            Section("Home routine") {
                Label(
                    "Home routine storage unavailable",
                    systemImage: "lock.trianglebadge.exclamationmark"
                )
                .foregroundStyle(.secondary)
            }
        } else if personalizationController.homeRoutine == nil {
            Section("Home routine") {
                Button {
                    showingHomeRoutineSettings = true
                } label: {
                    Label("Set home routine", systemImage: "house")
                }
            }
        }
    }

    private var stationTimeZones: [String: String] {
        Dictionary(
            uniqueKeysWithValues: dataService.stations.map {
                ($0.iata.uppercased(), $0.timeZone)
            }
        )
    }

    @ViewBuilder
    private var calendarStatusSection: some View {
        switch rosterController.calendarState {
        case .notDetermined, .available:
            Section("Calendar") {
                Button(action: connectCalendar) {
                    Label("Connect Calendar", systemImage: "calendar.badge.plus")
                }
            }
        case .requestingAccess:
            Section("Calendar") {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Connecting to Calendar")
                        .foregroundStyle(.secondary)
                }
            }
        case .scanning:
            EmptyView()
        case .accessDenied:
            Section("Calendar") {
                Label("Calendar access is off", systemImage: "calendar.badge.exclamationmark")
                    .foregroundStyle(.secondary)
                Button(action: openCalendarSettings) {
                    Label("Open Settings", systemImage: "gear")
                }
            }
        case .restricted:
            Section("Calendar") {
                Label(
                    "Calendar access is restricted on this device",
                    systemImage: "lock"
                )
                .foregroundStyle(.secondary)
            }
        case .noRosterFound:
            Section("Calendar") {
                Label(
                    "No roster update was found",
                    systemImage: "calendar.badge.exclamationmark"
                )
                .foregroundStyle(.secondary)
                Button(action: connectCalendar) {
                    Label("Check again", systemImage: "arrow.clockwise")
                }
            }
        case .selectionRequired(let options):
            Section("Choose roster calendar") {
                Text("More than one possible roster was found.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ForEach(options) { option in
                    Button {
                        selectCalendar(option.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option.title)
                            Text(calendarOptionDetail(option))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        case .synced:
            EmptyView()
        case .failed:
            Section("Calendar") {
                Label(
                    "Calendar could not be checked",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.secondary)
                Button(action: connectCalendar) {
                    Label("Try again", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private func connectCalendar() {
        Task {
            await rosterController.connectCalendar(
                stationTimeZones: stationTimeZones
            )
        }
    }

    private func selectCalendar(_ id: String) {
        Task {
            await rosterController.selectCalendar(
                id: id,
                stationTimeZones: stationTimeZones
            )
        }
    }

    private func openCalendarSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        openURL(url)
    }

    private func calendarOptionDetail(
        _ option: WAIRosterCalendarOption
    ) -> String {
        let range = option.start.formatted(date: .abbreviated, time: .omitted)
            + " - "
            + option.end.formatted(date: .abbreviated, time: .omitted)
        return "\(option.eventCount) activities, \(range)"
    }

    private var importFailureMessage: String {
        switch rosterController.importFailure {
        case .fileTooLarge:
            return "The selected file is too large to be a roster export."
        case .invalidFile:
            return "Select an iCal (.ics) roster exported by Portal DOV."
        case .unsupportedCompany:
            return "This file is not identified as a TAP Portal DOV roster."
        case .invalidRoster:
            return "The roster contains incomplete or invalid flight timing. Your earlier roster was kept."
        case .crewMismatch:
            return "This roster belongs to a different crew identifier."
        case .secureStorage:
            return "The roster could not be saved securely. Your earlier roster was kept."
        case nil:
            return "The roster could not be imported."
        }
    }

    private func groupedDuties(_ duties: [RosterDuty]) -> [WAI3DutyGroup] {
        let groups = Dictionary(grouping: duties) { duty in
            WAI3RosterFormatting.dateKey(for: duty)
        }
        return groups.keys.sorted().map { key in
            let groupDuties = groups[key, default: []].sorted {
                $0.start < $1.start
            }
            return WAI3DutyGroup(
                dateKey: key,
                title: groupDuties.first.map {
                    WAI3RosterFormatting.sectionDate(for: $0)
                } ?? key,
                duties: groupDuties
            )
        }
    }

    private func archiveScrollIdentifier(_ archive: RosterArchive) -> String {
        archive.segments
            .map { $0.document.source.sha256 }
            .sorted()
            .joined(separator: "|")
    }

    private func initialDutyID(
        in archive: RosterArchive,
        stays: [RosterStay]
    ) -> String? {
        RosterTimelineFocusResolver.dutyID(
            duties: archive.duties,
            stays: stays,
            now: Date()
        )
    }

    private static let iCalendarType = UTType(filenameExtension: "ics") ?? .data
}

private struct WAI3RosterAnalysisView: View {
    @ObservedObject var rosterController: WAIRosterController
    let refreshCalendarAction: () -> Void
    let importRosterAction: () -> Void

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Analysis")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch rosterController.state {
        case .idle, .loading:
            ProgressView("Loading roster")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failedSecureStorage:
            ContentUnavailableView(
                "Analysis unavailable",
                systemImage: "lock.trianglebadge.exclamationmark"
            )
        case .ready(let archive), .importing(let archive):
            analysisList(archive)
        }
    }

    @ViewBuilder
    private func analysisList(_ archive: RosterArchive) -> some View {
        if archive.duties.isEmpty {
            ContentUnavailableView(
                "No roster data",
                systemImage: "chart.bar.xaxis"
            )
        } else {
            let summary = RosterPeriodAnalyzer.summarize(archive.duties)
            let analyses = Dictionary(
                uniqueKeysWithValues: RosterDutyAnalyzer.analyze(
                    archive.duties
                ).map { ($0.dutyID, $0) }
            )
            let attention = RosterPeriodAnalyzer.attention(
                duties: archive.duties,
                issues: archive.issues
            )
            let dutiesByID = Dictionary(
                uniqueKeysWithValues: archive.duties.map { ($0.id, $0) }
            )

            List {
                if !attention.isEmpty {
                    attentionSection(
                        attention,
                        dutiesByID: dutiesByID
                    )
                }

                Section("Flight activity") {
                    LabeledContent(
                        "Rotations",
                        value: "\(summary.flightRotationCount)"
                    )
                    LabeledContent(
                        "Flight periods",
                        value: "\(summary.flightPeriodCount)"
                    )
                    LabeledContent("Legs", value: "\(summary.legCount)")
                    LabeledContent(
                        summary.unresolvedLegCount == 0
                            ? "Block time"
                            : "Resolved block time",
                        value: WAI3RosterFormatting.duration(
                            summary.resolvedBlockMinutes
                        )
                    )
                }

                Section("Intervals") {
                    LabeledContent(
                        "Measured",
                        value: "\(summary.measuredIntervalCount)"
                    )
                    if let shortest = summary.shortestMeasuredIntervalMinutes {
                        LabeledContent(
                            "Shortest",
                            value: WAI3RosterFormatting.duration(shortest)
                        )
                    }
                    if summary.activityReviewIntervalCount > 0 {
                        Label(
                            "\(summary.activityReviewIntervalCount) intervals need activity review",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.orange)
                    }
                }

                Section("Rotations") {
                    ForEach(
                        archive.duties.filter { $0.kind == .flight }
                    ) { duty in
                        if let analysis = analyses[duty.id] {
                            DisclosureGroup {
                                LabeledContent(
                                    "Roster span",
                                    value: WAI3RosterFormatting.duration(
                                        analysis.rosterSpanMinutes
                                    )
                                )
                                LabeledContent(
                                    analysis.unresolvedLegCount == 0
                                        ? "Block time"
                                        : "Resolved block time",
                                    value: WAI3RosterFormatting.duration(
                                        analysis.resolvedBlockMinutes
                                    )
                                )
                                LabeledContent(
                                    "Flight periods",
                                    value: "\(analysis.flightPeriods.count)"
                                )
                                if analysis.unresolvedLegCount > 0 {
                                    LabeledContent(
                                        "Legs to verify",
                                        value: "\(analysis.unresolvedLegCount)"
                                    )
                                }
                                intervalRow(analysis.intervalBefore)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(duty.activityCode)
                                        .fontWeight(.semibold)
                                    Text(rotationRoute(duty))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section("Assessment") {
                    LabeledContent("FTL limits", value: "Not assessed")
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func attentionSection(
        _ attention: RosterAnalysisAttention,
        dutiesByID: [String: RosterDuty]
    ) -> some View {
        Section("Needs attention") {
            if !attention.legVerifications.isEmpty {
                DisclosureGroup {
                    ForEach(attention.legVerifications) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(
                                "\(item.flightNumber) · \(item.originIATA) - \(item.destinationIATA)"
                            )
                            .fontWeight(.semibold)
                            Text(
                                "\(WAI3RosterFormatting.localDateTime(item.departure)) - \(WAI3RosterFormatting.localDateTime(item.arrival))"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            if !item.unresolvedStationIATAs.isEmpty {
                                Label(
                                    "Time zone unavailable: \(item.unresolvedStationIATAs.joined(separator: ", "))",
                                    systemImage: "clock.badge.exclamationmark"
                                )
                                .font(.caption)
                                .foregroundStyle(.orange)
                            }
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .combine)
                    }

                    Text(
                        "Confirm these local times in Portal DOV before relying on block or rest figures."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } label: {
                    Label(
                        verificationLabel(
                            count: attention.legVerifications.count
                        ),
                        systemImage: "clock.badge.exclamationmark"
                    )
                    .foregroundStyle(.orange)
                }
                .accessibilityIdentifier("wai3.analysis.legVerification")
            }

            if !attention.overlapConflicts.isEmpty {
                DisclosureGroup {
                    ForEach(attention.overlapConflicts) { conflict in
                        if let previous = dutiesByID[conflict.previousDutyID],
                           let current = dutiesByID[conflict.currentDutyID] {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(
                                    "\(current.activityCode) overlaps \(previous.activityCode)"
                                )
                                .fontWeight(.semibold)
                                conflictDutyRow("Earlier", duty: previous)
                                conflictDutyRow("Later", duty: current)
                                Text(
                                    "The later event starts \(WAI3RosterFormatting.duration(conflict.minutes)) before the earlier event ends."
                                )
                                .font(.caption)
                                .foregroundStyle(.orange)
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    Text(
                        "Correct the duplicate or stale event in the source roster, then check Calendar again or import an updated iCal."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    Button(action: refreshCalendarAction) {
                        Label("Check Calendar Again", systemImage: "arrow.clockwise")
                    }
                    Button(action: importRosterAction) {
                        Label(
                            "Import Updated iCal",
                            systemImage: "square.and.arrow.down"
                        )
                    }
                } label: {
                    Label(
                        overlapLabel(count: attention.overlapConflicts.count),
                        systemImage: "rectangle.on.rectangle.badge.exclamationmark"
                    )
                    .foregroundStyle(.orange)
                }
                .accessibilityIdentifier("wai3.analysis.overlapConflict")
            }
        }
    }

    private func conflictDutyRow(
        _ label: String,
        duty: RosterDuty
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(label): \(duty.activityCode) · \(rotationRoute(duty))")
                .font(.caption)
            Text(
                "\(WAI3RosterFormatting.dutyStart(duty)) - \(WAI3RosterFormatting.dutyEnd(duty))"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func verificationLabel(count: Int) -> String {
        count == 1
            ? "1 leg needs verification"
            : "\(count) legs need verification"
    }

    private func overlapLabel(count: Int) -> String {
        count == 1
            ? "1 roster overlap"
            : "\(count) roster overlaps"
    }

    @ViewBuilder
    private func intervalRow(_ interval: RosterIntervalAnalysis) -> some View {
        switch interval {
        case .measured(let minutes):
            LabeledContent(
                "Previous interval",
                value: WAI3RosterFormatting.duration(minutes)
            )
        case .overlap(let minutes):
            Label(
                "Overlap \(WAI3RosterFormatting.duration(minutes))",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.orange)
        case .interruptedByActivity:
            LabeledContent("Previous interval", value: "Needs review")
        case .notApplicable, .firstFlight:
            EmptyView()
        }
    }

    private func rotationRoute(_ duty: RosterDuty) -> String {
        guard let first = duty.legs.first,
              let last = duty.legs.last else {
            return WAI3RosterFormatting.dutyRange(duty)
        }
        return "\(first.originIATA) - \(last.destinationIATA)  ·  \(WAI3RosterFormatting.dutyRange(duty))"
    }
}

private struct WAI3DutyGroup {
    let dateKey: String
    let title: String
    let duties: [RosterDuty]
}

private struct WAI3DutySelection: Identifiable {
    let duty: RosterDuty
    let stay: RosterStay?
    let analysis: RosterDutyAnalysis?

    var id: String {
        duty.id
    }
}

private enum WAI3RoutineEditorSelection: Identifiable {
    case home(RosterHomeRoutine)
    case stay(
        stay: RosterStay,
        details: TimeCalculationDetails,
        override: RosterStayRoutineOverrideRecord?
    )

    var id: String {
        switch self {
        case .home(let routine):
            return "home-\(routine.dutyID)"
        case .stay(let stay, _, _):
            return "stay-\(stay.id)"
        }
    }
}

private struct WAI3RoutineEditorSheet: View {
    let selection: WAI3RoutineEditorSelection
    @ObservedObject var controller: WAIRosterPersonalizationController

    var body: some View {
        NavigationStack {
            switch selection {
            case .home(let routine):
                WAI3HomeRoutineOverrideView(
                    routine: routine,
                    controller: controller
                )
            case .stay(let stay, let details, let override):
                WAI3StayRoutineOverrideView(
                    stay: stay,
                    details: details,
                    override: override,
                    controller: controller
                )
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("wai3.routineEditor.sheet")
    }
}

private struct WAI3EmptyRosterView: View {
    let isImporting: Bool
    let calendarState: WAIRosterCalendarState
    let connectAction: () -> Void
    let selectAction: (String) -> Void
    let settingsAction: () -> Void
    let importAction: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Import your roster", systemImage: "calendar.badge.plus")
        } description: {
            Text(description)
        } actions: {
            VStack(spacing: 12) {
                calendarActions

                Button(action: importAction) {
                    Label("Choose iCal file", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.bordered)
                .disabled(isBusy)
            }
        }
    }

    private var description: String {
        switch calendarState {
        case .accessDenied:
            return "Allow Calendar access in Settings, or choose an iCal roster file."
        case .restricted:
            return "Calendar access is restricted. Choose an iCal roster file instead."
        case .noRosterFound:
            return "No roster was found in Calendar. Choose the iCal roster file instead."
        case .selectionRequired:
            return "More than one possible roster was found. Choose the correct calendar."
        case .failed:
            return "Calendar could not be checked. Try again or choose an iCal roster file."
        case .notDetermined, .available, .requestingAccess, .scanning, .synced:
            return "Connect Calendar to find your roster, or choose its iCal file."
        }
    }

    @ViewBuilder
    private var calendarActions: some View {
        switch calendarState {
        case .requestingAccess, .scanning:
            HStack(spacing: 10) {
                ProgressView()
                Text("Checking Calendar")
            }
            .foregroundStyle(.secondary)
        case .accessDenied:
            Button(action: settingsAction) {
                Label("Open Settings", systemImage: "gear")
            }
            .buttonStyle(.borderedProminent)
        case .restricted:
            EmptyView()
        case .selectionRequired(let options):
            ForEach(options) { option in
                Button {
                    selectAction(option.id)
                } label: {
                    Text(option.title)
                }
                .buttonStyle(.borderedProminent)
            }
        case .noRosterFound:
            Button(action: connectAction) {
                Label("Check again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
        case .failed:
            Button(action: connectAction) {
                Label("Try again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
        case .notDetermined, .available, .synced:
            Button(action: connectAction) {
                Label("Connect Calendar", systemImage: "calendar.badge.plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var isBusy: Bool {
        isImporting
            || calendarState == .requestingAccess
            || calendarState == .scanning
    }
}

private struct WAI3DutyRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let duty: RosterDuty
    let stay: RosterStay?
    let analysis: RosterDutyAnalysis?
    let homeRoutine: RosterHomeRoutine?
    let showsHomeRoutineSetup: Bool
    let roomNumber: String?
    let stayRoutineOverride: RosterStayRoutineOverrideRecord?
    let openDuty: () -> Void
    let openHotel: (() -> Void)?
    let editHomeRoutine: () -> Void
    let editStayRoutine: (TimeCalculationDetails) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: openDuty) {
                VStack(alignment: .leading, spacing: 8) {
                    dutyHeader
                    dutyMetrics

                    if duty.legs.isEmpty {
                        Text("Activity")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(duty.legs) { leg in
                            legRow(
                                leg,
                                blockMinutes: analysis?
                                    .analysis(for: leg.id)?
                                    .blockMinutes
                            )
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("wai3.roster.duty.\(duty.id)")

            if let homeRoutine {
                Divider()
                Button(action: editHomeRoutine) {
                    HStack(spacing: 10) {
                        homeRoutineSummary(homeRoutine)
                        Spacer(minLength: 8)
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(.blue)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(
                    "wai3.roster.homeRoutine.\(duty.id)"
                )
            } else if showsHomeRoutineSetup {
                Divider()
                Button(action: editHomeRoutine) {
                    Label("Set wake-up and pick-up", systemImage: "house")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }

            if let stay {
                Divider()
                Button(action: openHotel ?? openDuty) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Label(
                                stay.hotelName ?? stay.hotelCode,
                                systemImage: "bed.double"
                            )
                            .font(.subheadline)
                            .fontWeight(.medium)

                            Spacer(minLength: 8)

                            if openHotel != nil {
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let roomNumber {
                            Label(
                                "Room \(roomNumber)",
                                systemImage: "door.left.hand.closed"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    openHotel == nil
                        ? stay.hotelName ?? stay.hotelCode
                        : "Open hotel details for \(stay.hotelName ?? stay.hotelCode)"
                )
                .accessibilityIdentifier(
                    "wai3.roster.hotelDetails.\(stay.id)"
                )

                stayTiming
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func homeRoutineSummary(
        _ routine: RosterHomeRoutine
    ) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                homeRoutineVerticalSummary(routine)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        homeTimingLabel(
                            "Wake-up",
                            date: routine.wakeup,
                            systemImage: "alarm",
                            routine: routine
                        )
                        homeTimingLabel(
                            "Pick-up / leave home",
                            date: routine.leaveHome,
                            systemImage: "house",
                            routine: routine
                        )
                    }

                    homeRoutineVerticalSummary(routine)
                }
            }
        }
    }

    private func homeRoutineVerticalSummary(
        _ routine: RosterHomeRoutine
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            homeTimingLabel(
                "Wake-up",
                date: routine.wakeup,
                systemImage: "alarm",
                routine: routine
            )
            homeTimingLabel(
                "Pick-up / leave home",
                date: routine.leaveHome,
                systemImage: "house",
                routine: routine
            )
        }
    }

    private func homeTimingLabel(
        _ title: String,
        date: Date,
        systemImage: String,
        routine: RosterHomeRoutine
    ) -> some View {
        Label {
            Text(
                "\(title) \(WAI3RosterFormatting.compactDateTime(date, timeZoneIdentifier: routine.timeZoneIdentifier))"
            )
            .font(.caption.monospacedDigit())
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
        }
        .foregroundStyle(.secondary)
    }

    private var dutyHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                Text(duty.activityCode)
                    .font(.headline)

                Spacer()

                Text(WAI3RosterFormatting.dutyRange(duty))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(duty.activityCode)
                    .font(.headline)
                Text(WAI3RosterFormatting.dutyRange(duty))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var dutyMetrics: some View {
        if let analysis, duty.kind == .flight {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    durationLabel(
                        duty.hotelCode == nil ? "Roster span" : "Rotation span",
                        minutes: analysis.rosterSpanMinutes,
                        systemImage: "clock"
                    )
                    intervalBeforeLabel(analysis)
                }

                VStack(alignment: .leading, spacing: 4) {
                    durationLabel(
                        duty.hotelCode == nil ? "Roster span" : "Rotation span",
                        minutes: analysis.rosterSpanMinutes,
                        systemImage: "clock"
                    )
                    intervalBeforeLabel(analysis)
                }
            }
        }
    }

    private func legRow(
        _ leg: RosterLeg,
        blockMinutes: Int?
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Text(leg.flightNumber)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .leading)

                Text("\(leg.originIATA) - \(leg.destinationIATA)")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(WAI3RosterFormatting.legRange(leg))
                        .font(.caption.monospacedDigit())
                    if let blockMinutes {
                        Text(
                            "Block \(WAI3RosterFormatting.duration(blockMinutes))"
                        )
                        .font(.caption2)
                    }
                }
                .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(leg.flightNumber)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text("\(leg.originIATA) - \(leg.destinationIATA)")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(WAI3RosterFormatting.legRange(leg))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let blockMinutes {
                    Text(
                        "Block \(WAI3RosterFormatting.duration(blockMinutes))"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func durationLabel(
        _ title: String,
        minutes: Int,
        systemImage: String
    ) -> some View {
        Label(
            "\(title) \(WAI3RosterFormatting.duration(minutes))",
            systemImage: systemImage
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func intervalBeforeLabel(
        _ analysis: RosterDutyAnalysis
    ) -> some View {
        switch analysis.intervalBefore {
        case .overlap(let overlap):
            Label(
                "Overlap \(WAI3RosterFormatting.duration(overlap))",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        case .measured(let gap):
            durationLabel(
                "Interval",
                minutes: gap,
                systemImage: "moon.zzz"
            )
        case .interruptedByActivity:
            Label(
                "Interval needs activity review",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        case .notApplicable, .firstFlight:
            EmptyView()
        }
    }

    @ViewBuilder
    private var stayTiming: some View {
        if let stay {
            switch stay.timingStatus {
            case .calculated(let details):
            Button {
                editStayRoutine(details)
            } label: {
                HStack(spacing: 10) {
                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            stayTimingVertical(details, stay: stay)
                        } else {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 16) {
                                    stayTimingLabels(details, stay: stay)
                                }

                                stayTimingVertical(details, stay: stay)
                            }
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(.blue)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("wai3.roster.stayRoutine.\(stay.id)")

            if stay.requiresTransportConfirmation {
                Label("Confirm transfer option", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            case .nextDepartureMissing:
                statusLabel("Next roster leg needed", systemImage: "calendar.badge.exclamationmark")
            case .arrivalMissing, .sequenceMismatch:
                statusLabel("Stay sequence needs verification", systemImage: "exclamationmark.triangle")
            case .stationDataMissing:
                statusLabel("Transfer rule unavailable", systemImage: "clock.badge.exclamationmark")
            case .departureTimeUnresolved:
                statusLabel("Departure time needs verification", systemImage: "clock.badge.exclamationmark")
            case .calculationUnavailable:
                statusLabel("Automatic timing unavailable", systemImage: "exclamationmark.triangle")
            }
        }
    }

    private func stayTimingVertical(
        _ details: TimeCalculationDetails,
        stay: RosterStay
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            stayTimingLabels(details, stay: stay)
        }
    }

    @ViewBuilder
    private func stayTimingLabels(
        _ details: TimeCalculationDetails,
        stay: RosterStay
    ) -> some View {
        if let routine = RosterStayRoutineBuilder.routine(
            for: stay,
            override: stayRoutineOverride
        ), routine.usesOverride {
            timingLabel(
                "Wake-up",
                systemImage: "alarm",
                date: routine.wakeup,
                stationIATA: stay.stationIATA,
                timeZoneIdentifier: stay.stationTimeZoneIdentifier
            )
            timingLabel(
                "Pick-up",
                systemImage: "bus",
                date: routine.pickup,
                stationIATA: stay.stationIATA,
                timeZoneIdentifier: stay.stationTimeZoneIdentifier
            )
        } else {
            timingLabel(
                "Wake-up",
                systemImage: "alarm",
                window: details.wakeup,
                stationIATA: stay.stationIATA,
                timeZoneIdentifier: stay.stationTimeZoneIdentifier
            )
            timingLabel(
                "Pick-up",
                systemImage: "bus",
                window: details.pickup,
                stationIATA: stay.stationIATA,
                timeZoneIdentifier: stay.stationTimeZoneIdentifier
            )
        }
    }

    private func timingLabel(
        _ title: String,
        systemImage: String,
        window: TimeCalculationWindow,
        stationIATA: String,
        timeZoneIdentifier: String?
    ) -> some View {
        Label {
            Text("\(title) \(WAI3RosterFormatting.compactWindow(window, stationIATA: stationIATA, timeZoneIdentifier: timeZoneIdentifier))")
                .font(.caption.monospacedDigit())
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
        }
        .foregroundStyle(.secondary)
    }

    private func timingLabel(
        _ title: String,
        systemImage: String,
        date: Date,
        stationIATA: String,
        timeZoneIdentifier: String?
    ) -> some View {
        Label {
            Text(
                "\(title) \(WAI3RosterFormatting.compactWindow(TimeCalculationWindow(earliest: date, latest: date), stationIATA: stationIATA, timeZoneIdentifier: timeZoneIdentifier))"
            )
            .font(.caption.monospacedDigit())
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
        }
        .foregroundStyle(.secondary)
    }

    private func statusLabel(
        _ title: String,
        systemImage: String
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct WAI3DutyDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let duty: RosterDuty
    let stay: RosterStay?
    let analysis: RosterDutyAnalysis?
    let stations: [Station]
    let hotel: Hotel?
    @ObservedObject var rosterController: WAIRosterController
    @ObservedObject var roomNumberController: WAIRoomNumberController
    @ObservedObject var personalizationController:
        WAIRosterPersonalizationController
    @ObservedObject var hotelStayStore: HotelStayStore

    @State private var selectedHotel: Hotel?
    @State private var showingHomeRoutineSettings = false
    @State private var selectedRoutineEditor: WAI3RoutineEditorSelection?

    var body: some View {
        NavigationStack {
            List {
                Section(duty.kind == .flight ? "Roster event" : "Roster activity") {
                    LabeledContent("Activity", value: duty.activityCode)
                    LabeledContent(
                        duty.kind == .flight ? "Report" : "Start",
                        value: WAI3RosterFormatting.dutyStart(duty)
                    )
                    LabeledContent(
                        duty.kind == .flight ? "Release" : "End",
                        value: WAI3RosterFormatting.dutyEnd(duty)
                    )
                    if let analysis, duty.kind == .flight {
                        LabeledContent(
                            duty.hotelCode == nil ? "Roster span" : "Rotation span",
                            value: WAI3RosterFormatting.duration(
                                analysis.rosterSpanMinutes
                            )
                        )
                        switch analysis.intervalBefore {
                        case .overlap(let overlap):
                            Label(
                                "Overlaps the previous duty by \(WAI3RosterFormatting.duration(overlap))",
                                systemImage: "exclamationmark.triangle"
                            )
                            .foregroundStyle(.orange)
                        case .measured(let gap):
                            LabeledContent(
                                "Interval from previous release",
                                value: WAI3RosterFormatting.duration(gap)
                            )
                        case .interruptedByActivity:
                            Label(
                                "Interval needs activity review",
                                systemImage: "exclamationmark.triangle"
                            )
                            .foregroundStyle(.orange)
                        case .notApplicable, .firstFlight:
                            EmptyView()
                        }
                    }
                    if let hotelCode = duty.hotelCode {
                        LabeledContent("Hotel", value: hotelCode)
                    }
                }

                briefingSection

                crewSection

                homeDepartureSection

                if let analysis, !analysis.flightPeriods.isEmpty {
                    Section("Flight periods") {
                        ForEach(analysis.flightPeriods) { period in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Period \(period.index)")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                LabeledContent(
                                    "Legs",
                                    value: "\(period.legIDs.count)"
                                )
                                LabeledContent(
                                    period.unresolvedLegCount == 0
                                        ? "Block time"
                                        : "Resolved block time",
                                    value: WAI3RosterFormatting.duration(
                                        period.resolvedBlockMinutes
                                    )
                                )
                                if let window = period.flyingWindowMinutes {
                                    LabeledContent(
                                        "Flying window",
                                        value: WAI3RosterFormatting.duration(window)
                                    )
                                }
                                if let ground = period.groundToNextPeriodMinutes {
                                    LabeledContent(
                                        "Ground interval",
                                        value: WAI3RosterFormatting.duration(ground)
                                    )
                                }
                                if period.unresolvedLegCount > 0 {
                                    Label(
                                        "\(period.unresolvedLegCount) leg time needs verification",
                                        systemImage: "exclamationmark.triangle"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                if let stay {
                    Section("Stay") {
                        if let hotel {
                            Button {
                                selectedHotel = hotel
                            } label: {
                                LabeledContent {
                                    HStack(spacing: 8) {
                                        Text(hotel.displayName)
                                            .foregroundStyle(.primary)
                                        Image(systemName: "chevron.right")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } label: {
                                    Label("Hotel", systemImage: "bed.double")
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                "Open hotel details for \(hotel.displayName)"
                            )
                            .accessibilityIdentifier(
                                "wai3.stay.hotelDetails"
                            )
                            .help("Open hotel details")
                        } else {
                            LabeledContent(
                                "Hotel",
                                value: stay.hotelName ?? stay.hotelCode
                            )
                        }
                        if stay.hotelName != nil {
                            LabeledContent("Roster code", value: stay.hotelCode)
                        }
                        if let city = stay.hotelCity,
                           let country = stay.hotelCountry {
                            LabeledContent("Location", value: "\(city), \(country)")
                        }
                        if roomNumberController.state == .failedSecureStorage {
                            Label(
                                "Room number storage unavailable",
                                systemImage: "lock.trianglebadge.exclamationmark"
                            )
                            .foregroundStyle(.secondary)
                        } else {
                            NavigationLink {
                                WAI3RoomNumberEditView(
                                    stay: stay,
                                    controller: roomNumberController
                                )
                            } label: {
                                LabeledContent {
                                    HStack(spacing: 8) {
                                        Text(
                                            roomNumberController.roomNumber(
                                                for: stay.id
                                            ) ?? "Not set"
                                        )
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "pencil")
                                    }
                                } label: {
                                    Label(
                                        "Room",
                                        systemImage: "door.left.hand.closed"
                                    )
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Edit room number")
                            .help("Edit room number")
                        }
                        if let arrival = stay.arrivalLeg {
                            LabeledContent(
                                "Arrival",
                                value: WAI3RosterFormatting.localDateTime(
                                    arrival.arrival
                                )
                            )
                        }
                        if let departure = stay.departureLeg {
                            LabeledContent(
                                "Next departure",
                                value: WAI3RosterFormatting.localDateTime(
                                    departure.departure
                                )
                            )
                        }
                    }

                    Section("Wake-up and pick-up") {
                        WAI3StayTimingDetail(
                            stay: stay,
                            override: personalizationController
                                .stayRoutineOverride(for: stay.id),
                            editAction: { details in
                                selectedRoutineEditor = .stay(
                                    stay: stay,
                                    details: details,
                                    override: personalizationController
                                        .stayRoutineOverride(for: stay.id)
                                )
                            }
                        )
                    }
                }
            }
            .navigationTitle(duty.activityCode)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(item: $selectedHotel) { hotel in
            HotelDetailView(
                hotel: hotel,
                hotelStayStore: hotelStayStore
            )
        }
        .sheet(item: $selectedRoutineEditor) { selection in
            WAI3RoutineEditorSheet(
                selection: selection,
                controller: personalizationController
            )
        }
        .sheet(isPresented: $showingHomeRoutineSettings) {
            WAI3HomeRoutineSettingsView(
                stations: stations,
                controller: personalizationController,
                suggestedBaseIATA: duty.legs.first?.originIATA
            )
        }
    }

    @ViewBuilder
    private var homeDepartureSection: some View {
        if let homeRoutine {
            Section("Home departure") {
                Button {
                    selectedRoutineEditor = .home(homeRoutine)
                } label: {
                    LabeledContent(
                        "Wake-up",
                        value: WAI3RosterFormatting.absoluteDateTime(
                            homeRoutine.wakeup,
                            stationIATA: homeRoutine.stationIATA,
                            timeZoneIdentifier: homeRoutine.timeZoneIdentifier
                        )
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("wai3.homeRoutine.wakeupLink")
                Button {
                    selectedRoutineEditor = .home(homeRoutine)
                } label: {
                    LabeledContent(
                        "Pick-up / leave home",
                        value: WAI3RosterFormatting.absoluteDateTime(
                            homeRoutine.leaveHome,
                            stationIATA: homeRoutine.stationIATA,
                            timeZoneIdentifier: homeRoutine.timeZoneIdentifier
                        )
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("wai3.homeRoutine.pickupLink")
                LabeledContent(
                    "Report",
                    value: WAI3RosterFormatting.absoluteDateTime(
                        homeRoutine.report,
                        stationIATA: homeRoutine.stationIATA,
                        timeZoneIdentifier: homeRoutine.timeZoneIdentifier
                    )
                )
                LabeledContent(
                    "Travel",
                    value: "\(homeRoutine.travelMinutes) min"
                )
                if homeRoutine.usesDutyOverride {
                    Label(
                        "Adjusted for this duty",
                        systemImage: "slider.horizontal.3"
                    )
                    .foregroundStyle(.blue)
                }
                Button {
                    showingHomeRoutineSettings = true
                } label: {
                    Label("Edit default routine", systemImage: "pencil")
                }
            }
        } else if personalizationController.state == .failedSecureStorage,
                  duty.kind == .flight {
            Section("Home departure") {
                Label(
                    "Home routine storage unavailable",
                    systemImage: "lock.trianglebadge.exclamationmark"
                )
                .foregroundStyle(.secondary)
            }
        } else if personalizationController.homeRoutine == nil,
                  duty.kind == .flight,
                  let originIATA = duty.legs.first?.originIATA {
            Section("Home departure") {
                Button {
                    showingHomeRoutineSettings = true
                } label: {
                    Label(
                        "Set wake-up and pick-up",
                        systemImage: "house"
                    )
                }
                .accessibilityIdentifier("wai3.homeRoutine.setup")

                Text(
                    "Confirm your travel time from home for departures from \(originIATA)."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var briefingSection: some View {
        if !duty.legs.isEmpty {
            Section("Flights") {
                ForEach(duty.legs) { leg in
                    let briefing = personalizationController.briefing(
                        for: leg.id
                    )
                    let actual = personalizationController.actualFlight(
                        for: leg.id
                    )
                    NavigationLink {
                        WAI3LegBriefingEditView(
                            duty: duty,
                            leg: leg,
                            rosterBlockMinutes: analysis?
                                .analysis(for: leg.id)?
                                .blockMinutes,
                            stations: stations,
                            controller: personalizationController,
                            rosterController: rosterController
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(leg.flightNumber)
                                    .font(.headline)
                                Text(
                                    "\(leg.originIATA) - \(leg.destinationIATA)"
                                )
                                .font(.subheadline)
                                Spacer()
                                Text(WAI3RosterFormatting.legRange(leg))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 14) {
                                    briefingMetric(
                                        "Pax",
                                        value: briefing?.passengerLoad
                                            ?? leg.passengerLoad
                                            ?? "Not set"
                                    )
                                    briefingMetric(
                                        "Flight",
                                        value: effectiveFlightTime(
                                            for: leg,
                                            briefing: briefing
                                        )
                                    )
                                    briefingMetric(
                                        "Password",
                                        value: briefing?.commanderPassword == nil
                                            ? "Not set"
                                            : "Saved"
                                    )
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    briefingMetric(
                                        "Pax",
                                        value: briefing?.passengerLoad
                                            ?? leg.passengerLoad
                                            ?? "Not set"
                                    )
                                    briefingMetric(
                                        "Flight",
                                        value: effectiveFlightTime(
                                            for: leg,
                                            briefing: briefing
                                        )
                                    )
                                }
                            }
                            if let actual {
                                actualFlightSummary(actual, leg: leg)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    .accessibilityIdentifier(
                        "wai3.briefing.edit.\(leg.id)"
                    )

                    briefingCalendarStatus(for: leg)

                }
            }
        }
    }

    private func briefingMetric(_ title: String, value: String) -> some View {
        Text("\(title) \(value)")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func actualFlightSummary(
        _ actual: RosterLegActualFlightRecord,
        leg: RosterLeg
    ) -> some View {
        if let landing = actual.landingAt,
           let duration = actual.durationMinutes {
            Label {
                Text(
                    "Actual \(WAI3RosterFormatting.absoluteDateTime(actual.takeoffAt, stationIATA: leg.originIATA, timeZoneIdentifier: leg.departure.timeZoneIdentifier)) → \(WAI3RosterFormatting.absoluteDateTime(landing, stationIATA: leg.destinationIATA, timeZoneIdentifier: leg.arrival.timeZoneIdentifier)) · \(WAI3RosterFormatting.duration(duration))"
                )
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .font(.caption)
            .foregroundStyle(.green)
        } else {
            Label(
                "Airborne since \(WAI3RosterFormatting.absoluteDateTime(actual.takeoffAt, stationIATA: leg.originIATA, timeZoneIdentifier: leg.departure.timeZoneIdentifier))",
                systemImage: "airplane"
            )
            .font(.caption)
            .foregroundStyle(.blue)
        }
    }

    @ViewBuilder
    private var crewSection: some View {
        switch WAI3CrewPresentation.resolve(
            crews: duty.legs.map(\.crew)
        ) {
        case .unavailable:
            EmptyView()
        case .shared(let crew):
            Section("Crew") {
                ForEach(crew) { member in
                    crewMemberRow(member, scope: "shared")
                }
            }
        case .perLeg:
            ForEach(duty.legs) { leg in
                Section(
                    "Crew · \(leg.flightNumber)  \(leg.originIATA) - \(leg.destinationIATA)"
                ) {
                    if leg.crew.isEmpty {
                        Text("Crew not available")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(leg.crew) { member in
                            crewMemberRow(member, scope: leg.id)
                        }
                    }
                }
            }
        }
    }

    private func crewMemberRow(
        _ member: RosterCrewMember,
        scope: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(member.name)
                .fontWeight(.medium)
            HStack(spacing: 10) {
                Text(member.roleCode)
                    .font(.caption.monospaced())
                Text(member.employeeIdentifier)
                    .font(.caption.monospacedDigit())
                if member.isDeadhead {
                    Text("DHC")
                        .font(.caption)
                }
            }
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(
            "wai3.crew.member.\(scope).\(member.id)"
        )
    }

    @ViewBuilder
    private func briefingCalendarStatus(for leg: RosterLeg) -> some View {
        switch rosterController.briefingCalendarSyncState(for: leg.id) {
        case .syncing:
            HStack(spacing: 10) {
                ProgressView()
                Text("Updating Calendar")
            }
            .foregroundStyle(.secondary)
        case .synced(let calendarTitle):
            Label(
                "Calendar updated · \(calendarTitle)",
                systemImage: "calendar.badge.checkmark"
            )
            .foregroundStyle(.green)
            .accessibilityIdentifier("wai3.briefing.calendarSynced")
        case .removed(let calendarTitle):
            Label(
                "Calendar reset · \(calendarTitle)",
                systemImage: "calendar"
            )
            .foregroundStyle(.secondary)
        case .notAuthorized:
            Label(
                "Calendar access is required",
                systemImage: "calendar.badge.exclamationmark"
            )
            .foregroundStyle(.orange)
        case .sourceEventNotFound:
            Label(
                "Roster event not found in Calendar",
                systemImage: "calendar.badge.exclamationmark"
            )
            .foregroundStyle(.orange)
        case .readOnly:
            Label(
                "Roster calendar is read-only",
                systemImage: "lock"
            )
            .foregroundStyle(.orange)
        case .failed:
            Label(
                "Calendar update failed",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.orange)
        case nil:
            EmptyView()
        }
    }

    private var homeRoutine: RosterHomeRoutine? {
        RosterHomeRoutineBuilder.routine(
            for: duty,
            settings: personalizationController.homeRoutine,
            override: personalizationController.homeRoutineOverride(
                for: duty.id
            )
        )
    }

    private func effectiveFlightTime(
        for leg: RosterLeg,
        briefing: RosterLegBriefingRecord?
    ) -> String {
        if let minutes = briefing?.plannedFlightMinutes
            ?? analysis?.analysis(for: leg.id)?.blockMinutes {
            return WAI3RosterFormatting.duration(minutes)
        }
        return "Not set"
    }
}

private struct WAI3RoomNumberEditView: View {
    @Environment(\.dismiss) private var dismiss
    let stay: RosterStay
    @ObservedObject var controller: WAIRoomNumberController

    @State private var roomNumber = ""

    var body: some View {
        Form {
            Section("Room") {
                TextField("Room number", text: $roomNumber)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(save)
                    .onChange(of: roomNumber) {
                        if roomNumber.count > 64 {
                            roomNumber = String(roomNumber.prefix(64))
                        }
                    }
            }
        }
        .navigationTitle(stay.hotelName ?? stay.hotelCode)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
            }
        }
        .onAppear {
            roomNumber = controller.roomNumber(for: stay.id) ?? ""
        }
        .alert(
            "Room number not saved",
            isPresented: Binding(
                get: { controller.saveFailed },
                set: { isPresented in
                    if !isPresented {
                        controller.clearSaveFailure()
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                controller.clearSaveFailure()
            }
        } message: {
            Text("The previous room number was kept.")
        }
    }

    private func save() {
        if controller.setRoomNumber(roomNumber, for: stay.id) {
            dismiss()
        }
    }
}

private struct WAI3HomeRoutineSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let stations: [Station]
    @ObservedObject var controller: WAIRosterPersonalizationController
    let suggestedBaseIATA: String?

    @State private var baseIATA = ""
    @State private var travelMinutes = 45
    @State private var wakeupBufferMinutes = 60

    var body: some View {
        NavigationStack {
            Form {
                Section("Base") {
                    Picker("Airport", selection: $baseIATA) {
                        Text("Choose airport").tag("")
                        ForEach(sortedStations) { station in
                            Text("\(station.iata) · \(station.city)")
                                .tag(station.iata)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    .accessibilityIdentifier("wai3.homeRoutine.base")
                }

                Section("Home to airport") {
                    Stepper(
                        "Travel: \(travelMinutes) min",
                        value: $travelMinutes,
                        in: 5...300,
                        step: 5
                    )
                    Stepper(
                        "Wake-up buffer: \(wakeupBufferMinutes) min",
                        value: $wakeupBufferMinutes,
                        in: 0...300,
                        step: 5
                    )
                }
            }
            .navigationTitle("Home routine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(
                            baseIATA.isEmpty
                            || controller.state != .ready
                        )
                }
            }
            .onAppear(perform: load)
            .alert(
                "Home routine not saved",
                isPresented: saveFailureBinding
            ) {
                Button("OK", role: .cancel) {
                    controller.clearSaveFailure()
                }
            } message: {
                Text("The previous home routine was kept.")
            }
        }
    }

    private var sortedStations: [Station] {
        stations.sorted { $0.iata < $1.iata }
    }

    private var saveFailureBinding: Binding<Bool> {
        Binding(
            get: { controller.saveFailed },
            set: { isPresented in
                if !isPresented {
                    controller.clearSaveFailure()
                }
            }
        )
    }

    private func load() {
        if let settings = controller.homeRoutine {
            baseIATA = settings.baseIATA
            travelMinutes = settings.travelMinutes
            wakeupBufferMinutes = settings.wakeupBufferMinutes
            return
        }

        guard let suggestedBaseIATA,
              stations.contains(where: { $0.iata == suggestedBaseIATA }) else {
            return
        }
        baseIATA = suggestedBaseIATA
    }

    private func save() {
        if controller.setHomeRoutine(
            baseIATA: baseIATA,
            travelMinutes: travelMinutes,
            wakeupBufferMinutes: wakeupBufferMinutes
        ) {
            dismiss()
        }
    }
}

private enum WAI3RoutineEditorField: String, CaseIterable, Identifiable {
    case wakeup
    case pickup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wakeup: "Wake-up"
        case .pickup: "Pick-up"
        }
    }
}

private struct WAI3RoutineEditorBody: View {
    @Binding var wakeup: Date
    @Binding var pickup: Date
    let reportText: String
    let pickupTitle: String
    let pickupSystemImage: String
    let timeZone: TimeZone
    let isValid: Bool
    let resetTitle: String?
    let resetAction: (() -> Void)?

    @State private var selectedField: WAI3RoutineEditorField = .wakeup

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                HStack(spacing: 12) {
                    Image(systemName: "airplane.departure")
                        .font(.title2)
                        .foregroundStyle(.blue)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Report")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(reportText)
                            .font(.subheadline.monospacedDigit())
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 0) {
                    timeSummary(
                        title: "Wake-up",
                        systemImage: "alarm",
                        date: wakeup
                    )
                    Divider()
                        .frame(height: 48)
                    timeSummary(
                        title: pickupTitle,
                        systemImage: pickupSystemImage,
                        date: pickup
                    )
                }

                Picker("Time to adjust", selection: $selectedField) {
                    Text("Wake-up").tag(WAI3RoutineEditorField.wakeup)
                    Text(pickupTitle).tag(WAI3RoutineEditorField.pickup)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("wai3.routineEditor.field")

                DatePicker(
                    selectedField == .wakeup ? "Wake-up" : pickupTitle,
                    selection: selectedTime,
                    displayedComponents: [.hourAndMinute]
                )
                .datePickerStyle(.wheel)
                .labelsHidden()
                .accessibilityIdentifier(
                    selectedField == .wakeup
                        ? "wai3.routineEditor.wakeup"
                        : "wai3.routineEditor.pickup"
                )

                if !isValid {
                    Label(
                        "Wake-up must be before pick-up",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let resetTitle, let resetAction {
                    Button(resetTitle, action: resetAction)
                        .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var selectedTime: Binding<Date> {
        Binding(
            get: {
                selectedField == .wakeup ? wakeup : pickup
            },
            set: { value in
                if selectedField == .wakeup {
                    wakeup = value
                } else {
                    pickup = value
                }
            }
        )
    }

    private func timeSummary(
        title: String,
        systemImage: String,
        date: Date
    ) -> some View {
        VStack(spacing: 5) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(formattedTime(date))
                .font(.title2.monospacedDigit())
                .fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity)
    }

    private func formattedTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

private struct WAI3HomeRoutineOverrideView: View {
    @Environment(\.dismiss) private var dismiss
    let routine: RosterHomeRoutine
    @ObservedObject var controller: WAIRosterPersonalizationController

    @State private var wakeup: Date
    @State private var leaveHome: Date

    init(
        routine: RosterHomeRoutine,
        controller: WAIRosterPersonalizationController
    ) {
        self.routine = routine
        self.controller = controller
        _wakeup = State(initialValue: routine.wakeup)
        _leaveHome = State(initialValue: routine.leaveHome)
    }

    var body: some View {
        WAI3RoutineEditorBody(
            wakeup: $wakeup,
            pickup: $leaveHome,
            reportText: WAI3RosterFormatting.absoluteDateTime(
                routine.report,
                stationIATA: routine.stationIATA,
                timeZoneIdentifier: routine.timeZoneIdentifier
            ),
            pickupTitle: "Leave home",
            pickupSystemImage: "house",
            timeZone: routineTimeZone,
            isValid: resolvedTimes != nil,
            resetTitle: routine.usesDutyOverride ? "Use default times" : nil,
            resetAction: routine.usesDutyOverride ? useDefaults : nil
        )
        .environment(\.timeZone, routineTimeZone)
        .navigationTitle("Adjust home departure")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(!canSave)
            }
        }
        .alert(
            "Home departure not saved",
            isPresented: saveFailureBinding
        ) {
            Button("OK", role: .cancel) {
                controller.clearSaveFailure()
            }
        } message: {
            Text("The previous times were kept.")
        }
    }

    private var canSave: Bool {
        controller.state == .ready
        && resolvedTimes != nil
    }

    private var resolvedTimes: (wakeup: Date, pickup: Date)? {
        WAI3RoutineTimeResolver.resolvedPair(
            wakeupClock: wakeup,
            pickupClock: leaveHome,
            report: routine.report,
            timeZoneIdentifier: routine.timeZoneIdentifier
        )
    }

    private var routineTimeZone: TimeZone {
        TimeZone(identifier: routine.timeZoneIdentifier) ?? .current
    }

    private var saveFailureBinding: Binding<Bool> {
        Binding(
            get: { controller.saveFailed },
            set: { isPresented in
                if !isPresented {
                    controller.clearSaveFailure()
                }
            }
        )
    }

    private func save() {
        guard let resolvedTimes else { return }
        if controller.setHomeRoutineOverride(
            for: routine.dutyID,
            report: routine.report,
            wakeup: resolvedTimes.wakeup,
            leaveHome: resolvedTimes.pickup
        ) {
            dismiss()
        }
    }

    private func useDefaults() {
        if controller.clearHomeRoutineOverride(for: routine.dutyID) {
            dismiss()
        }
    }
}

private struct WAI3DurationWheelPicker: View {
    @Binding var hours: Int
    @Binding var minutes: Int
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 0) {
            Picker("Hours", selection: $hours) {
                ForEach(0...24, id: \.self) { value in
                    Text("\(value) h").tag(value)
                }
            }
            .pickerStyle(.wheel)
            .accessibilityIdentifier("wai3.briefing.flightHours")
            .frame(maxWidth: .infinity)

            Divider()
                .frame(height: 120)

            Picker("Minutes", selection: $minutes) {
                ForEach(0..<60, id: \.self) { value in
                    Text(String(format: "%02d min", value)).tag(value)
                }
            }
            .pickerStyle(.wheel)
            .accessibilityIdentifier("wai3.briefing.flightMinutes")
            .frame(maxWidth: .infinity)
        }
        .frame(height: 160)
        .clipped()
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.62)
        .onChange(of: hours) {
            if hours == 24 {
                minutes = 0
            }
        }
    }
}

private struct WAI3LegBriefingEditView: View {
    @Environment(\.dismiss) private var dismiss
    let duty: RosterDuty
    let leg: RosterLeg
    let rosterBlockMinutes: Int?
    let stations: [Station]
    @ObservedObject var controller: WAIRosterPersonalizationController
    @ObservedObject var rosterController: WAIRosterController

    @State private var passengerLoad = ""
    @State private var usesCustomFlightTime = false
    @State private var flightHours = 0
    @State private var flightMinutes = 0
    @State private var commanderPassword = ""
    @State private var showsPassword = false
    @State private var isSaving = false
    @State private var weatherState: WeatherState = .idle

    private enum WeatherState {
        case idle
        case loading
        case available([AviationWeatherReport])
        case unavailable
    }

    var body: some View {
        Form {
            Section("Flight") {
                LabeledContent(
                    "Route",
                    value: "\(leg.originIATA) - \(leg.destinationIATA)"
                )
                LabeledContent(
                    "Departure",
                    value: WAI3RosterFormatting.localDateTime(leg.departure)
                )
                LabeledContent(
                    "Arrival",
                    value: WAI3RosterFormatting.localDateTime(leg.arrival)
                )
                LabeledContent(
                    "Roster duration",
                    value: rosterFlightMinutes.map(
                        WAI3RosterFormatting.duration
                    ) ?? "Time zone unresolved"
                )
                if let registration = leg.aircraftRegistration {
                    LabeledContent("Aircraft", value: registration)
                }
                if let aircraftName = leg.aircraftName {
                    LabeledContent("Type", value: aircraftName)
                }
            }

            Section("Passengers") {
                TextField("Pax", text: $passengerLoad)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("wai3.briefing.pax")
                    .onChange(of: passengerLoad) {
                        if passengerLoad.count > 128 {
                            passengerLoad = String(passengerLoad.prefix(128))
                        }
                    }
                if let rosterValue = leg.passengerLoad {
                    LabeledContent("Roster", value: rosterValue)
                }
            }

            Section("Flight time") {
                LabeledContent(
                    "Roster time",
                    value: rosterFlightMinutes.map(
                        WAI3RosterFormatting.duration
                    ) ?? "Not available"
                )

                Picker(
                    "Flight time source",
                    selection: $usesCustomFlightTime
                ) {
                    Text("Roster").tag(false)
                    Text("Briefing").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("wai3.briefing.flightTimeMode")
                .onChange(of: usesCustomFlightTime) {
                    if usesCustomFlightTime {
                        if customFlightMinutes == nil {
                            applyFlightMinutes(rosterFlightMinutes ?? 60)
                        }
                    } else {
                        applyFlightMinutes(rosterFlightMinutes ?? 0)
                    }
                }

                WAI3DurationWheelPicker(
                    hours: $flightHours,
                    minutes: $flightMinutes,
                    isEnabled: usesCustomFlightTime
                )

                if !usesCustomFlightTime, rosterFlightMinutes != nil {
                    Label("Using roster time", systemImage: "calendar")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if usesCustomFlightTime, customFlightMinutes == nil {
                    Label(
                        "Choose a duration from 1 minute to 24 hours.",
                        systemImage: "exclamationmark.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.red)
                }
            }

            Section("Commander password") {
                HStack(spacing: 8) {
                    Group {
                        if showsPassword {
                            TextField(
                                "Password",
                                text: $commanderPassword
                            )
                        } else {
                            SecureField(
                                "Password",
                                text: $commanderPassword
                            )
                        }
                    }
                    .textContentType(.none)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("wai3.briefing.password")

                    Button {
                        showsPassword.toggle()
                    } label: {
                        Image(
                            systemName: showsPassword ? "eye.slash" : "eye"
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        showsPassword ? "Hide password" : "Show password"
                    )

                    if !commanderPassword.isEmpty {
                        Button(role: .destructive) {
                            commanderPassword = ""
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove password")
                    }
                }
                .onChange(of: commanderPassword) {
                    if commanderPassword.count > 256 {
                        commanderPassword = String(
                            commanderPassword.prefix(256)
                        )
                    }
                }

                Text("Kept on this iPhone until removed or you sign out.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Special passengers") {
                Text("INF (—)   WCHS (—)   WCHR (—)")
                Text("WCHC (—)   UM (—)   NAV (—)")
            }

            weatherSection

            if !leg.crew.isEmpty {
                Section("Crew") {
                    ForEach(leg.crew) { member in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(member.name)
                                .fontWeight(.medium)
                            HStack(spacing: 10) {
                                Text(member.roleCode)
                                Text(member.employeeIdentifier)
                                if member.isDeadhead {
                                    Text("DHC")
                                }
                            }
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(leg.flightNumber)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        await save()
                    }
                }
                .disabled(!canSave || isSaving)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear(perform: load)
        .task(id: weatherStationCodes) {
            await loadWeather()
        }
        .alert(
            "Briefing not saved",
            isPresented: saveFailureBinding
        ) {
            Button("OK", role: .cancel) {
                controller.clearSaveFailure()
            }
        } message: {
            Text("The previous briefing details were kept.")
        }
    }

    @ViewBuilder
    private var weatherSection: some View {
        Section("Weather and METAR") {
            switch weatherState {
            case .idle, .loading:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading airport weather")
                        .foregroundStyle(.secondary)
                }
            case .available(let reports):
                ForEach(reports) { report in
                    weatherReport(report)
                }
                Button {
                    Task { await loadWeather() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            case .unavailable:
                Label(
                    "Weather unavailable",
                    systemImage: "cloud.slash"
                )
                .foregroundStyle(.secondary)
                Button {
                    Task { await loadWeather() }
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private func weatherReport(
        _ report: AviationWeatherReport
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(report.icaoID)
                    .font(.subheadline.monospaced())
                    .fontWeight(.semibold)
                if let category = report.flightCategory {
                    Text(category)
                        .font(.caption)
                        .foregroundStyle(weatherColor(category))
                }
                Spacer()
                if let observationTime = report.observationTime {
                    Text(observationTime, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(weatherSummary(report))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(report.rawObservation)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
    }

    private func weatherSummary(_ report: AviationWeatherReport) -> String {
        var parts: [String] = []
        if let speed = report.windSpeedKnots {
            let direction = report.windDirectionDegrees.map {
                String(format: "%03d°", $0)
            } ?? "VRB"
            let gust = report.windGustKnots.map { " G\($0)" } ?? ""
            parts.append("Wind \(direction) \(speed)\(gust) kt")
        }
        if let temperature = report.temperatureCelsius {
            parts.append("\(temperature.formatted(.number.precision(.fractionLength(0))))°C")
        }
        if let visibility = report.visibility {
            parts.append("Vis \(visibility)")
        }
        if let pressure = report.altimeterHPa {
            parts.append("QNH \(Int(pressure.rounded()))")
        }
        return parts.isEmpty ? "Decoded weather unavailable" : parts.joined(separator: " · ")
    }

    private func weatherColor(_ category: String) -> Color {
        switch category.uppercased() {
        case "VFR": return .green
        case "MVFR": return .blue
        case "IFR": return .red
        case "LIFR": return .purple
        default: return .secondary
        }
    }

    private var weatherStationCodes: [String] {
        [leg.originIATA, leg.destinationIATA].compactMap { iata in
            stations.first { $0.iata == iata }?.icao
        }
    }

    private func loadWeather() async {
        guard !weatherStationCodes.isEmpty else {
            weatherState = .unavailable
            return
        }
        weatherState = .loading
        do {
            let reports = try await AviationWeatherService.reports(
                for: weatherStationCodes
            )
            guard !Task.isCancelled else { return }
            weatherState = .available(reports)
        } catch {
            guard !Task.isCancelled else { return }
            weatherState = .unavailable
        }
    }

    private var canSave: Bool {
        controller.state == .ready
        && (
            !usesCustomFlightTime
                || customFlightMinutes != nil
        )
    }

    private var customFlightMinutes: Int? {
        WAI3FlightDurationInput.totalMinutes(
            hours: flightHours,
            minutes: flightMinutes
        )
    }

    private var rosterFlightMinutes: Int? {
        if let rosterBlockMinutes {
            return rosterBlockMinutes
        }
        guard let departure = leg.departure.instant,
              let arrival = leg.arrival.instant,
              arrival > departure else {
            return nil
        }
        let minutes = Int(arrival.timeIntervalSince(departure) / 60)
        return minutes > 0 ? minutes : nil
    }

    private var saveFailureBinding: Binding<Bool> {
        Binding(
            get: { controller.saveFailed },
            set: { isPresented in
                if !isPresented {
                    controller.clearSaveFailure()
                }
            }
        )
    }

    private func load() {
        guard let briefing = controller.briefing(for: leg.id) else {
            applyFlightMinutes(rosterFlightMinutes ?? 0)
            return
        }
        passengerLoad = briefing.passengerLoad ?? ""
        commanderPassword = briefing.commanderPassword ?? ""
        if let minutes = briefing.plannedFlightMinutes {
            usesCustomFlightTime = true
            applyFlightMinutes(minutes)
        } else {
            applyFlightMinutes(rosterFlightMinutes ?? 0)
        }
    }

    private func applyFlightMinutes(_ totalMinutes: Int) {
        let bounded = min(max(totalMinutes, 0), 1_440)
        flightHours = bounded / 60
        flightMinutes = bounded == 1_440 ? 0 : bounded % 60
    }

    private func save() async {
        isSaving = true
        let plannedFlightMinutes = usesCustomFlightTime
            ? customFlightMinutes
            : nil
        guard controller.setBriefing(
            for: leg.id,
            passengerLoad: passengerLoad,
            plannedFlightMinutes: plannedFlightMinutes,
            commanderPassword: commanderPassword
        ) else {
            isSaving = false
            return
        }
        await rosterController.syncBriefingToCalendar(
            duty: duty,
            leg: leg,
            plannedFlightMinutes: plannedFlightMinutes
        )
        isSaving = false
        dismiss()
    }
}

private struct WAI3StayTimingDetail: View {
    let stay: RosterStay
    let override: RosterStayRoutineOverrideRecord?
    let editAction: (TimeCalculationDetails) -> Void

    var body: some View {
        switch stay.timingStatus {
        case .calculated(let details):
            Button {
                editAction(details)
            } label: {
                LabeledContent(
                    "Wake-up",
                    value: effectiveTime(
                        details.wakeup,
                        keyPath: \.wakeup
                    )
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("wai3.stay.wakeupLink")
            Button {
                editAction(details)
            } label: {
                LabeledContent(
                    "Pick-up",
                    value: effectiveTime(
                        details.pickup,
                        keyPath: \.pickup
                    )
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("wai3.stay.pickupLink")
            LabeledContent(
                "Report",
                value: WAI3RosterFormatting.absoluteDateTime(
                    details.report,
                    stationIATA: stay.stationIATA,
                    timeZoneIdentifier: stay.stationTimeZoneIdentifier
                )
            )
            LabeledContent(
                "Transfer",
                value: transferLabel(details)
            )
            if let rule = details.appliedRuleLabel {
                LabeledContent("Rule", value: rule)
            }
            if stay.reportTimeSource == .standardBeforeDeparture {
                LabeledContent("Report basis", value: "60 min before departure")
            } else {
                LabeledContent("Report basis", value: "Roster")
            }
            if let alternative = stay.automaticallySelectedAlternative {
                LabeledContent("Transfer option", value: alternative)
            }
            if stay.requiresTransportConfirmation {
                Label(
                    "Confirm the transfer option",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
            }
            if override != nil {
                Label(
                    "Adjusted for this stay",
                    systemImage: "slider.horizontal.3"
                )
                .foregroundStyle(.blue)
            }
        case .nextDepartureMissing:
            status(
                "The next roster leg is needed before wake-up and pick-up can be calculated.",
                systemImage: "calendar.badge.exclamationmark"
            )
        case .arrivalMissing:
            status(
                "The hotel could not be linked to an arrival leg.",
                systemImage: "exclamationmark.triangle"
            )
        case .sequenceMismatch(let nextOriginIATA):
            status(
                "The next leg starts in \(nextOriginIATA), not \(stay.stationIATA).",
                systemImage: "exclamationmark.triangle"
            )
        case .stationDataMissing:
            status(
                "No current transfer rule is available for \(stay.stationIATA).",
                systemImage: "clock.badge.exclamationmark"
            )
        case .departureTimeUnresolved:
            status(
                "The next departure time zone needs verification.",
                systemImage: "clock.badge.exclamationmark"
            )
        case .calculationUnavailable:
            status(
                "The current transfer rules do not produce an automatic timing.",
                systemImage: "exclamationmark.triangle"
            )
        }
    }

    private func effectiveTime(
        _ defaultWindow: TimeCalculationWindow,
        keyPath: KeyPath<RosterStayRoutine, Date>
    ) -> String {
        if let routine = RosterStayRoutineBuilder.routine(
            for: stay,
            override: override
        ), routine.usesOverride {
            return WAI3RosterFormatting.absoluteDateTime(
                routine[keyPath: keyPath],
                stationIATA: stay.stationIATA,
                timeZoneIdentifier: stay.stationTimeZoneIdentifier
            )
        }
        return WAI3RosterFormatting.fullWindow(
            defaultWindow,
            stationIATA: stay.stationIATA,
            timeZoneIdentifier: stay.stationTimeZoneIdentifier
        )
    }

    private func transferLabel(_ details: TimeCalculationDetails) -> String {
        if details.usesTransportRange {
            return "\(details.minimumTransportMinutes)-\(details.maximumTransportMinutes) min"
        }
        return "\(details.maximumTransportMinutes) min"
    }

    private func status(
        _ message: String,
        systemImage: String
    ) -> some View {
        Label(message, systemImage: systemImage)
            .foregroundStyle(.secondary)
    }
}

private struct WAI3StayRoutineOverrideView: View {
    @Environment(\.dismiss) private var dismiss
    let stay: RosterStay
    let details: TimeCalculationDetails
    let override: RosterStayRoutineOverrideRecord?
    @ObservedObject var controller: WAIRosterPersonalizationController

    @State private var wakeup: Date
    @State private var pickup: Date

    init(
        stay: RosterStay,
        details: TimeCalculationDetails,
        override: RosterStayRoutineOverrideRecord?,
        controller: WAIRosterPersonalizationController
    ) {
        self.stay = stay
        self.details = details
        self.override = override
        self.controller = controller
        let routine = RosterStayRoutineBuilder.routine(
            for: stay,
            override: override
        )
        _wakeup = State(initialValue: routine?.wakeup ?? details.wakeup.earliest)
        _pickup = State(initialValue: routine?.pickup ?? details.pickup.earliest)
    }

    var body: some View {
        WAI3RoutineEditorBody(
            wakeup: $wakeup,
            pickup: $pickup,
            reportText: WAI3RosterFormatting.absoluteDateTime(
                details.report,
                stationIATA: stay.stationIATA,
                timeZoneIdentifier: stay.stationTimeZoneIdentifier
            ),
            pickupTitle: "Pick-up",
            pickupSystemImage: "bus",
            timeZone: stayTimeZone,
            isValid: resolvedTimes != nil,
            resetTitle: override == nil ? nil : "Use calculated times",
            resetAction: override == nil ? nil : useCalculatedTimes
        )
        .environment(\.timeZone, stayTimeZone)
        .navigationTitle("Adjust hotel routine")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(controller.state != .ready || resolvedTimes == nil)
            }
        }
        .alert(
            "Hotel routine not saved",
            isPresented: saveFailureBinding
        ) {
            Button("OK", role: .cancel) {
                controller.clearSaveFailure()
            }
        } message: {
            Text("The previous times were kept.")
        }
    }

    private var resolvedTimes: (wakeup: Date, pickup: Date)? {
        WAI3RoutineTimeResolver.resolvedPair(
            wakeupClock: wakeup,
            pickupClock: pickup,
            report: details.report,
            timeZoneIdentifier: stay.stationTimeZoneIdentifier ?? "UTC"
        )
    }

    private var stayTimeZone: TimeZone {
        TimeZone(identifier: stay.stationTimeZoneIdentifier ?? "UTC") ?? .gmt
    }

    private var saveFailureBinding: Binding<Bool> {
        Binding(
            get: { controller.saveFailed },
            set: { isPresented in
                if !isPresented {
                    controller.clearSaveFailure()
                }
            }
        )
    }

    private func save() {
        guard let resolvedTimes else { return }
        if controller.setStayRoutineOverride(
            for: stay.id,
            report: details.report,
            wakeup: resolvedTimes.wakeup,
            pickup: resolvedTimes.pickup
        ) {
            dismiss()
        }
    }

    private func useCalculatedTimes() {
        if controller.clearStayRoutineOverride(for: stay.id) {
            dismiss()
        }
    }
}

private enum WAI3RosterFormatting {
    static func duration(_ totalMinutes: Int) -> String {
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 {
            return "\(minutes)m"
        }
        if minutes == 0 {
            return "\(hours)h"
        }
        return "\(hours)h \(minutes)m"
    }

    static func dateKey(for duty: RosterDuty) -> String {
        formatter(
            format: "yyyy-MM-dd",
            timeZoneIdentifier: duty.startTimeZoneIdentifier
        ).string(from: duty.start)
    }

    static func sectionDate(for duty: RosterDuty) -> String {
        formatter(
            format: "EEEE, d MMMM",
            timeZoneIdentifier: duty.startTimeZoneIdentifier
        ).string(from: duty.start)
    }

    static func dutyRange(_ duty: RosterDuty) -> String {
        let startFormatter = formatter(
            format: "HH:mm",
            timeZoneIdentifier: duty.startTimeZoneIdentifier
        )
        let endFormatter = formatter(
            format: "HH:mm",
            timeZoneIdentifier: duty.endTimeZoneIdentifier
        )
        return "\(startFormatter.string(from: duty.start)) - \(endFormatter.string(from: duty.end))"
    }

    static func dutyStart(_ duty: RosterDuty) -> String {
        formatter(
            format: "d MMM yyyy, HH:mm",
            timeZoneIdentifier: duty.startTimeZoneIdentifier
        ).string(from: duty.start)
    }

    static func dutyEnd(_ duty: RosterDuty) -> String {
        formatter(
            format: "d MMM yyyy, HH:mm",
            timeZoneIdentifier: duty.endTimeZoneIdentifier
        ).string(from: duty.end)
    }

    static func legRange(_ leg: RosterLeg) -> String {
        "\(time(leg.departure)) - \(time(leg.arrival))"
    }

    static func localDateTime(_ value: RosterLocalDateTime) -> String {
        let day = String(format: "%02d", value.day)
        let hour = String(format: "%02d", value.hour)
        let minute = String(format: "%02d", value.minute)
        return "\(day) \(month(value.month)) \(value.year), \(hour):\(minute)"
    }

    static func compactWindow(
        _ window: TimeCalculationWindow,
        stationIATA: String,
        timeZoneIdentifier: String?
    ) -> String {
        let timeZone = resolvedTimeZone(timeZoneIdentifier)
        let day = formatter(
            format: "d MMM, HH:mm",
            timeZone: timeZone
        )
        if window.isExact {
            return "\(day.string(from: window.earliest)) \(stationIATA)"
        }

        let calendar = calendar(timeZone: timeZone)
        if calendar.isDate(
            window.earliest,
            inSameDayAs: window.latest
        ) {
            let end = formatter(format: "HH:mm", timeZone: timeZone)
            return "\(day.string(from: window.earliest))-\(end.string(from: window.latest)) \(stationIATA)"
        }
        return "\(day.string(from: window.earliest))-\(day.string(from: window.latest)) \(stationIATA)"
    }

    static func fullWindow(
        _ window: TimeCalculationWindow,
        stationIATA: String,
        timeZoneIdentifier: String?
    ) -> String {
        let timeZone = resolvedTimeZone(timeZoneIdentifier)
        let date = formatter(
            format: "d MMM yyyy, HH:mm",
            timeZone: timeZone
        )
        if window.isExact {
            return "\(date.string(from: window.earliest)) \(stationIATA)"
        }

        let calendar = calendar(timeZone: timeZone)
        if calendar.isDate(
            window.earliest,
            inSameDayAs: window.latest
        ) {
            let end = formatter(format: "HH:mm", timeZone: timeZone)
            return "\(date.string(from: window.earliest))-\(end.string(from: window.latest)) \(stationIATA)"
        }
        return "\(date.string(from: window.earliest))-\(date.string(from: window.latest)) \(stationIATA)"
    }

    static func absoluteDateTime(
        _ date: Date,
        stationIATA: String,
        timeZoneIdentifier: String?
    ) -> String {
        let timeZone = resolvedTimeZone(timeZoneIdentifier)
        return "\(formatter(format: "d MMM yyyy, HH:mm", timeZone: timeZone).string(from: date)) \(stationIATA)"
    }

    static func compactDateTime(
        _ date: Date,
        timeZoneIdentifier: String
    ) -> String {
        formatter(
            format: "d MMM, HH:mm",
            timeZoneIdentifier: timeZoneIdentifier
        ).string(from: date)
    }

    private static func time(_ value: RosterLocalDateTime) -> String {
        String(format: "%02d:%02d", value.hour, value.minute)
    }

    private static func month(_ value: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .current
        let symbols = calendar.shortMonthSymbols
        guard symbols.indices.contains(value - 1) else {
            return ""
        }
        return symbols[value - 1]
    }

    private static func formatter(
        format: String,
        timeZoneIdentifier: String
    ) -> DateFormatter {
        formatter(
            format: format,
            timeZone: TimeZone(identifier: timeZoneIdentifier) ?? .gmt
        )
    }

    private static func formatter(
        format: String,
        timeZone: TimeZone
    ) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }

    private static func resolvedTimeZone(_ identifier: String?) -> TimeZone {
        identifier.flatMap(TimeZone.init(identifier:)) ?? .gmt
    }

    private static func calendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}
