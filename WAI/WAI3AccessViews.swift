import AuthenticationServices
import SwiftUI
import UIKit

@MainActor
struct WAI3AccessRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var accessController: WAIAccessController
    @StateObject private var operationalDataController:
        WAIProtectedOperationalDataController
    @StateObject private var rosterController: WAIRosterController
    @StateObject private var roomNumberController: WAIRoomNumberController
    @StateObject private var personalizationController:
        WAIRosterPersonalizationController
    @StateObject private var calculationHistoryStore: CalculationHistoryStore
    @StateObject private var hotelStayStore: HotelStayStore
    @StateObject private var privacyShieldController =
        WAI3PrivacyShieldWindowController()
    private let approvalEmail: String
    private let privacyPolicyURL: URL

    @State private var showingAccount = false
    @State private var retainedApprovedAccess: WAIApprovedAccess?

    init(runtime: WAI3Runtime) {
        _accessController = StateObject(wrappedValue: runtime.accessController)
        _operationalDataController = StateObject(
            wrappedValue: runtime.operationalDataController
        )
        _rosterController = StateObject(wrappedValue: runtime.rosterController)
        _roomNumberController = StateObject(
            wrappedValue: runtime.roomNumberController
        )
        _personalizationController = StateObject(
            wrappedValue: runtime.personalizationController
        )
        _calculationHistoryStore = StateObject(
            wrappedValue: runtime.calculationHistoryStore
        )
        _hotelStayStore = StateObject(
            wrappedValue: runtime.hotelStayStore
        )
        approvalEmail = runtime.configuration.approvalEmail
        privacyPolicyURL = runtime.configuration.privacyPolicyURL
    }

    var body: some View {
        content
            .background(
                WAI3PrivacyShieldWindowAttachment(
                    controller: privacyShieldController,
                    isVisible: scenePhase != .active
                )
            )
            .task {
                if accessController.state == .restoring {
                    await accessController.restoreAccess()
                }
            }
            .onChange(of: accessController.state) {
                handleAccessState(accessController.state)
            }
            .onChange(of: scenePhase) {
                handleScenePhase(scenePhase)
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: ASAuthorizationAppleIDProvider
                        .credentialRevokedNotification
                )
            ) { _ in
                Task {
                    await accessController.handleAppleCredentialRevocation()
                }
            }
            .sheet(isPresented: $showingAccount) {
                accountSheet
            }
    }

    @ViewBuilder
    private var content: some View {
        switch accessController.state {
        case .restoring:
            WAI3ProgressView(message: "Restoring access")
        case .signedOut:
            WAI3SignInView(
                privacyPolicyURL: privacyPolicyURL,
                signIn: { credential in
                    Task {
                        await accessController.signIn(with: credential)
                    }
                }
            )
        case .signingIn:
            WAI3ProgressView(message: "Signing in")
        case .checkingApproval:
            if let retainedApprovedAccess {
                approvedContent(retainedApprovedAccess)
            } else {
                WAI3ProgressView(message: "Checking access")
            }
        case .signingOut:
            WAI3ProgressView(message: "Signing out")
        case .pending(let pending):
            WAI3PendingAccessView(
                pending: pending,
                approvalEmail: approvalEmail,
                privacyPolicyURL: privacyPolicyURL,
                refresh: {
                    Task { await accessController.refreshAccess() }
                },
                signOut: {
                    Task { await accessController.signOut() }
                },
                deleteAccount: { credential in
                    await deleteAccount(with: credential)
                }
            )
        case .approved(let access):
            approvedContent(access)
        case .revoked:
            WAI3RevokedAccessView(
                privacyPolicyURL: privacyPolicyURL,
                signOut: {
                    Task { await accessController.signOut() }
                },
                deleteAccount: { credential in
                    await deleteAccount(with: credential)
                }
            )
        case .failed(let failure):
            WAI3AccessFailureView(
                failure: failure,
                retry: {
                    Task { await accessController.restoreAccess() }
                },
                signOut: {
                    Task { await accessController.signOut() }
                }
            )
        }
    }

    @ViewBuilder
    private func approvedContent(_ access: WAIApprovedAccess) -> some View {
        switch operationalDataController.state {
        case .idle, .loading:
            WAI3ProgressView(message: "Loading operational data")
        case .ready(let ready):
            VStack(spacing: 0) {
                if ready.syncState != .current {
                    WAI3DataStatusBanner(syncState: ready.syncState)
                }

                WAI3CrewWorkspaceView(
                    rosterController: rosterController,
                    roomNumberController: roomNumberController,
                    personalizationController: personalizationController,
                    calculationHistoryStore: calculationHistoryStore,
                    hotelStayStore: hotelStayStore,
                    dataService: operationalDataController.dataService,
                    hotelDataService: operationalDataController.hotelDataService,
                    whatsNewDataService: operationalDataController.whatsNewDataService,
                    accountAction: { showingAccount = true }
                )
            }
        case .failed(let failure):
            WAI3OperationalDataFailureView(
                failure: failure,
                retry: {
                    Task {
                        if failure == .authorization {
                            await accessController.refreshAccess()
                        } else {
                            await operationalDataController.prepare(for: access)
                        }
                    }
                },
                signOut: {
                    Task { await accessController.signOut() }
                }
            )
        }
    }

    @ViewBuilder
    private var accountSheet: some View {
        if let access = presentedApprovedAccess {
            WAI3AccountView(
                access: access,
                dataState: operationalDataController.state,
                privacyPolicyURL: privacyPolicyURL,
                refresh: {
                    Task {
                        await operationalDataController.prepare(for: access)
                    }
                },
                signOut: {
                    showingAccount = false
                    Task { await accessController.signOut() }
                },
                deleteAccount: { credential in
                    await deleteAccount(with: credential)
                }
            )
        } else {
            Color.clear
        }
    }

    private func handleAccessState(_ state: WAIAccessState) {
        switch state {
        case .approved(let access):
            retainedApprovedAccess = access
            rosterController.prepare(for: access.userID)
            roomNumberController.prepare(for: access.userID)
            personalizationController.prepare(for: access.userID)
            calculationHistoryStore.prepare(for: access.userID)
            hotelStayStore.prepare(for: access.userID)
            Task {
                await operationalDataController.prepare(for: access)
            }
        case .checkingApproval:
            break
        case .restoring, .signedOut, .signingIn, .signingOut, .pending,
             .revoked, .failed:
            retainedApprovedAccess = nil
            showingAccount = false
            operationalDataController.reset()
            rosterController.reset()
            roomNumberController.reset()
            personalizationController.reset()
            calculationHistoryStore.resetProtectedMemory()
            hotelStayStore.resetProtectedMemory()
        }
    }

    private var presentedApprovedAccess: WAIApprovedAccess? {
        if case .approved(let access) = accessController.state {
            return access
        }
        if accessController.state == .checkingApproval {
            return retainedApprovedAccess
        }
        return nil
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        guard phase == .active else {
            return
        }

        switch accessController.state {
        case .approved, .pending:
            Task {
                await accessController.refreshAccess()
            }
        case .restoring, .signedOut, .signingIn, .checkingApproval,
             .signingOut, .revoked, .failed:
            break
        }
    }

    private func deleteAccount(
        with credential: WAIAppleSignInCredential
    ) async -> WAIAccountDeletionResult {
        let result = await accessController.deleteAccount(with: credential)
        if result == .deleted {
            showingAccount = false
        }
        return result
    }
}

@MainActor
final class WAI3PrivacyShieldWindowController: ObservableObject {
    private weak var window: UIWindow?
    private var hostingController: UIHostingController<WAI3PrivacyShield>?
    private var shouldShowShield = false

    var isShieldVisible: Bool {
        hostingController?.view.superview != nil
    }

    func attach(to window: UIWindow?) {
        guard self.window !== window else {
            updateVisibility()
            return
        }
        hostingController?.view.removeFromSuperview()
        self.window = window
        updateVisibility()
    }

    func setVisible(_ isVisible: Bool) {
        shouldShowShield = isVisible
        updateVisibility()
    }

    private func updateVisibility() {
        guard shouldShowShield, let window else {
            hostingController?.view.removeFromSuperview()
            return
        }

        let hostingController: UIHostingController<WAI3PrivacyShield>
        if let existing = self.hostingController {
            hostingController = existing
        } else {
            hostingController = UIHostingController(
                rootView: WAI3PrivacyShield()
            )
            hostingController.view.backgroundColor = .systemBackground
            hostingController.view.accessibilityIdentifier =
                "wai3.privacyShieldWindow"
            self.hostingController = hostingController
        }

        hostingController.loadViewIfNeeded()
        guard let shield = hostingController.view else {
            return
        }
        guard shield.superview !== window else {
            window.bringSubviewToFront(shield)
            return
        }
        shield.removeFromSuperview()
        shield.frame = window.bounds
        shield.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(shield)
    }
}

private struct WAI3PrivacyShieldWindowAttachment: UIViewRepresentable {
    let controller: WAI3PrivacyShieldWindowController
    let isVisible: Bool

    func makeUIView(context: Context) -> WAI3WindowProbeView {
        let view = WAI3WindowProbeView()
        view.isUserInteractionEnabled = false
        view.onWindowChange = { [weak controller] window in
            controller?.attach(to: window)
        }
        controller.setVisible(isVisible)
        return view
    }

    func updateUIView(_ uiView: WAI3WindowProbeView, context: Context) {
        controller.attach(to: uiView.window)
        controller.setVisible(isVisible)
    }
}

private final class WAI3WindowProbeView: UIView {
    var onWindowChange: ((UIWindow?) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?(window)
    }
}

private struct WAI3PrivacyShield: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                Image(systemName: "clock.badge.checkmark")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(.blue)
                    .accessibilityHidden(true)

                Text("WAI")
                    .font(.title2)
                    .fontWeight(.bold)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("WAI protected")
        .accessibilityIdentifier("wai3.privacyShield")
    }
}

private struct WAI3SignInView: View {
    @Environment(\.colorScheme) private var colorScheme
    let privacyPolicyURL: URL
    let signIn: (WAIAppleSignInCredential) -> Void

    @State private var pendingNonce: String?
    @State private var errorMessage: String?
    private let nonceGenerator = WAIAppleSignInNonceGenerator()

    var body: some View {
        VStack(spacing: 0) {
            WAI3BrandHeader()

            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        Spacer(minLength: 32)

                        VStack(spacing: 16) {
                            Image(systemName: "clock.badge.checkmark")
                                .font(.system(size: 44, weight: .medium))
                                .foregroundStyle(.blue)
                                .accessibilityHidden(true)

                            Text("Crew timing, ready when you are")
                                .font(.title2)
                                .fontWeight(.semibold)
                                .multilineTextAlignment(.center)

                            Text("Sign in to continue.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            SignInWithAppleButton(
                                .continue,
                                onRequest: prepare,
                                onCompletion: complete
                            )
                            .signInWithAppleButtonStyle(
                                colorScheme == .dark ? .white : .black
                            )
                            .id(colorScheme)
                            .frame(maxWidth: 360)
                            .frame(height: 50)

                            if let errorMessage {
                                Text(errorMessage)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .multilineTextAlignment(.center)
                            }

                            Text("Authentication is provided by Apple. Access requires approval.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 360)

                            Link(destination: privacyPolicyURL) {
                                Label("Privacy Policy", systemImage: "hand.raised")
                            }
                            .font(.caption)
                            .accessibilityIdentifier("wai3.privacyPolicy")
                        }
                        .padding(.horizontal, 24)

                        Spacer(minLength: 32)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .background(Color(.systemBackground))
    }

    private func prepare(_ request: ASAuthorizationAppleIDRequest) {
        do {
            let nonce = try nonceGenerator.makeRequest()
            pendingNonce = nonce.rawNonce
            request.nonce = nonce.hashedNonce
            request.requestedScopes = [.email]
            errorMessage = nil
        } catch {
            pendingNonce = nil
            request.nonce = WAIAppleSignInNonceGenerator.sha256("invalid-request")
            errorMessage = "Sign in could not be prepared. Please try again."
        }
    }

    private func complete(
        _ result: Result<ASAuthorization, Error>
    ) {
        defer { pendingNonce = nil }

        switch result {
        case .success(let authorization):
            guard let appleCredential = authorization.credential
                    as? ASAuthorizationAppleIDCredential else {
                errorMessage = "Apple returned an unsupported credential."
                return
            }
            do {
                let credential = try WAIAppleSignInCredentialFactory.make(
                    identityToken: appleCredential.identityToken,
                    authorizationCode: appleCredential.authorizationCode,
                    rawNonce: pendingNonce
                )
                errorMessage = nil
                signIn(credential)
            } catch {
                errorMessage = "Apple did not return a valid identity token."
            }
        case .failure(let error):
            let mapped = WAIAppleAuthorizationErrorMapper.map(error)
            errorMessage = mapped == .cancelled
                ? nil
                : "Sign in could not be completed. Please try again."
        }
    }
}

private struct WAI3PendingAccessView: View {
    let pending: WAIPendingAccess
    let approvalEmail: String
    let privacyPolicyURL: URL
    let refresh: () -> Void
    let signOut: () -> Void
    let deleteAccount:
        (WAIAppleSignInCredential) async -> WAIAccountDeletionResult

    var body: some View {
        WAI3StatusScreen(
            icon: "hourglass",
            title: "Approval pending",
            message: "Send the approval request from your company email account."
        ) {
            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    Text(pending.approvalCode)
                        .font(.system(.title3, design: .monospaced))
                        .fontWeight(.semibold)
                        .textSelection(.enabled)

                    Button {
                        UIPasteboard.general.string = pending.approvalCode
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy approval code")
                    .accessibilityLabel("Copy approval code")
                }
                .padding(14)
                .frame(maxWidth: 360)
                .background(.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Text("Include your crew name, TAP number, and the code above.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let approvalEmailURL {
                    Link(destination: approvalEmailURL) {
                        Label("Prepare approval email", systemImage: "envelope")
                            .frame(maxWidth: 360)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Text("These details are used only to validate access and are handled as private and confidential.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)

                Link(destination: privacyPolicyURL) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
                .font(.subheadline)
                .accessibilityIdentifier("wai3.privacyPolicy")

                Button(action: refresh) {
                    Label("Check again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)

                Button("Sign out", role: .destructive, action: signOut)
                    .font(.subheadline)

                WAI3DeleteAccountButton(
                    bordered: true,
                    deleteAccount: deleteAccount
                )
            }
        }
    }

    private var approvalEmailURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = approvalEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: "WAI access request"),
            URLQueryItem(name: "body", value: approvalEmailBody)
        ]
        return components.url
    }

    private var approvalEmailBody: String {
        """
        Hello,

        I would like to request access to WAI.

        Crew name:
        TAP number:
        Approval code: \(pending.approvalCode)
        """
    }
}

private struct WAI3RevokedAccessView: View {
    let privacyPolicyURL: URL
    let signOut: () -> Void
    let deleteAccount:
        (WAIAppleSignInCredential) async -> WAIAccountDeletionResult

    var body: some View {
        WAI3StatusScreen(
            icon: "lock.slash",
            title: "Access unavailable",
            message: "This account is no longer authorized to use WAI."
        ) {
            VStack(spacing: 12) {
                Button("Sign out", role: .destructive, action: signOut)
                    .buttonStyle(.bordered)

                WAI3DeleteAccountButton(
                    bordered: true,
                    deleteAccount: deleteAccount
                )

                Link(destination: privacyPolicyURL) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
                .font(.subheadline)
                .accessibilityIdentifier("wai3.privacyPolicy")
            }
        }
    }
}

private struct WAI3AccessFailureView: View {
    let failure: WAIAccessFailure
    let retry: () -> Void
    let signOut: () -> Void

    var body: some View {
        WAI3StatusScreen(
            icon: icon,
            title: title,
            message: message
        ) {
            VStack(spacing: 12) {
                Button(action: retry) {
                    Label("Try again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)

                if failure != .configuration {
                    Button("Sign out", role: .destructive, action: signOut)
                        .font(.subheadline)
                }
            }
        }
    }

    private var icon: String {
        failure == .secureStorage ? "lock.trianglebadge.exclamationmark" : "exclamationmark.triangle"
    }

    private var title: String {
        switch failure {
        case .configuration:
            return "Configuration unavailable"
        case .authentication:
            return "Sign in required"
        case .invalidServerResponse:
            return "Access could not be verified"
        case .secureStorage:
            return "Protected storage unavailable"
        case .serviceUnavailable:
            return "Service temporarily unavailable"
        }
    }

    private var message: String {
        switch failure {
        case .configuration:
            return "This build is not configured for secure access."
        case .authentication:
            return "Please sign in again to continue."
        case .invalidServerResponse:
            return "WAI stopped before loading protected data. Please try again."
        case .secureStorage:
            return "WAI could not safely read or clear local credentials."
        case .serviceUnavailable:
            return "Check your connection and try again."
        }
    }
}

private struct WAI3OperationalDataFailureView: View {
    let failure: WAIProtectedDataFailure
    let retry: () -> Void
    let signOut: () -> Void

    var body: some View {
        WAI3StatusScreen(
            icon: failure == .secureStorage
                ? "lock.trianglebadge.exclamationmark"
                : "doc.badge.exclamationmark",
            title: title,
            message: message
        ) {
            VStack(spacing: 12) {
                Button(action: retry) {
                    Label("Try again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)

                Button("Sign out", role: .destructive, action: signOut)
                    .font(.subheadline)
            }
        }
    }

    private var title: String {
        switch failure {
        case .unavailable:
            return "Operational data unavailable"
        case .authorization:
            return "Access could not be verified"
        case .secureStorage:
            return "Protected storage unavailable"
        }
    }

    private var message: String {
        switch failure {
        case .unavailable:
            return "WAI could not load a complete, validated data set."
        case .authorization:
            return "WAI stopped before showing protected operational data."
        case .secureStorage:
            return "WAI could not safely access local protected data."
        }
    }
}

private struct WAI3AccountView: View {
    @Environment(\.dismiss) private var dismiss
    let access: WAIApprovedAccess
    let dataState: WAIProtectedDataState
    let privacyPolicyURL: URL
    let refresh: () -> Void
    let signOut: () -> Void
    let deleteAccount:
        (WAIAppleSignInCredential) async -> WAIAccountDeletionResult

    var body: some View {
        NavigationStack {
            List {
                Section("Access") {
                    LabeledContent("Status", value: accessLabel)
                    LabeledContent(
                        "Last verified",
                        value: access.lastVerifiedAt.formatted(
                            date: .abbreviated,
                            time: .shortened
                        )
                    )
                }

                Section("Operational data") {
                    LabeledContent("Status", value: dataLabel)

                    Button(action: refresh) {
                        Label("Check for updates", systemImage: "arrow.clockwise")
                    }
                }

                Section("Account actions") {
                    Button("Sign out", role: .destructive, action: signOut)

                    WAI3DeleteAccountButton(
                        bordered: false,
                        deleteAccount: deleteAccount
                    )
                }

                Section("Privacy") {
                    Link(destination: privacyPolicyURL) {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }
                    .accessibilityIdentifier("wai3.privacyPolicy")
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var accessLabel: String {
        switch access.mode {
        case .online:
            return "Online"
        case .offline:
            return "Offline"
        }
    }

    private var dataLabel: String {
        guard case .ready(let ready) = dataState else {
            return "Checking"
        }
        switch ready.syncState {
        case .current:
            return "Current"
        case .offline:
            return "Offline"
        case .refreshDeferred:
            return "Update pending"
        case .remoteRejected:
            return "Verified local copy"
        }
    }
}

private struct WAI3DeleteAccountButton: View {
    let bordered: Bool
    let deleteAccount:
        (WAIAppleSignInCredential) async -> WAIAccountDeletionResult

    @State private var confirmingDeletion = false
    @State private var authorizingDeletion = false

    var body: some View {
        Group {
            if bordered {
                deletionButton
                    .buttonStyle(.bordered)
            } else {
                deletionButton
            }
        }
        .confirmationDialog(
            "Permanently delete this account?",
            isPresented: $confirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Continue", role: .destructive) {
                authorizingDeletion = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This removes the WAI account and all protected local data. This cannot be undone."
            )
        }
        .sheet(isPresented: $authorizingDeletion) {
            WAI3DeleteAccountAuthorizationView(
                deleteAccount: deleteAccount
            )
        }
    }

    private var deletionButton: some View {
        Button("Delete account", role: .destructive) {
            confirmingDeletion = true
        }
    }
}

private struct WAI3DeleteAccountAuthorizationView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    let deleteAccount:
        (WAIAppleSignInCredential) async -> WAIAccountDeletionResult

    @State private var pendingNonce: String?
    @State private var errorMessage: String?
    @State private var isDeleting = false
    private let nonceGenerator = WAIAppleSignInNonceGenerator()

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 20) {
                        Spacer(minLength: 24)

                        Image(systemName: "person.crop.circle.badge.minus")
                            .font(.system(size: 44, weight: .medium))
                            .foregroundStyle(.red)
                            .accessibilityHidden(true)

                        Text("Confirm account deletion")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .multilineTextAlignment(.center)

                        Text(
                            "Sign in with the Apple Account linked to WAI. No account or data is deleted unless Apple and the server both confirm the request."
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)

                        if isDeleting {
                            ProgressView("Deleting account")
                        } else {
                            SignInWithAppleButton(
                                .continue,
                                onRequest: prepare,
                                onCompletion: complete
                            )
                            .signInWithAppleButtonStyle(
                                colorScheme == .dark ? .white : .black
                            )
                            .id(colorScheme)
                            .frame(maxWidth: 360)
                            .frame(height: 50)
                        }

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 420)
                        }

                        Spacer(minLength: 24)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .navigationTitle("Delete Account")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isDeleting)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isDeleting)
                }
            }
        }
    }

    private func prepare(_ request: ASAuthorizationAppleIDRequest) {
        do {
            let nonce = try nonceGenerator.makeRequest()
            pendingNonce = nonce.rawNonce
            request.nonce = nonce.hashedNonce
            request.requestedScopes = []
            errorMessage = nil
        } catch {
            pendingNonce = nil
            request.nonce = WAIAppleSignInNonceGenerator.sha256(
                "invalid-request"
            )
            errorMessage = "Account deletion could not be prepared. Please try again."
        }
    }

    private func complete(
        _ result: Result<ASAuthorization, Error>
    ) {
        defer { pendingNonce = nil }

        switch result {
        case .success(let authorization):
            guard let appleCredential = authorization.credential
                    as? ASAuthorizationAppleIDCredential else {
                errorMessage = "Apple returned an unsupported credential."
                return
            }

            let credential: WAIAppleSignInCredential
            do {
                credential = try WAIAppleSignInCredentialFactory.make(
                    identityToken: appleCredential.identityToken,
                    authorizationCode: appleCredential.authorizationCode,
                    rawNonce: pendingNonce
                )
                guard credential.isValidForAccountDeletion else {
                    throw WAIAppleSignInPreparationError.invalidAuthorizationCode
                }
            } catch {
                errorMessage = "Apple did not return a valid deletion authorization."
                return
            }

            isDeleting = true
            errorMessage = nil
            Task {
                let deletionResult = await deleteAccount(credential)
                isDeleting = false
                switch deletionResult {
                case .deleted:
                    dismiss()
                case .failed(let failure):
                    errorMessage = message(for: failure)
                }
            }
        case .failure(let error):
            let mapped = WAIAppleAuthorizationErrorMapper.map(error)
            errorMessage = mapped == .cancelled
                ? nil
                : "Apple could not confirm account deletion. Please try again."
        }
    }

    private func message(
        for failure: WAIAccountDeletionFailure
    ) -> String {
        switch failure {
        case .authentication:
            return "Apple could not confirm this WAI account. Nothing was deleted."
        case .connection:
            return "WAI could not confirm the deletion result. Access has been stopped to protect your data."
        case .serviceUnavailable:
            return "WAI could not confirm the deletion result. Access has been stopped to protect your data."
        case .invalidServerResponse:
            return "The response could not be verified. WAI stopped access to protect your data."
        case .secureStorage:
            return "WAI could not safely clear local credentials. Access has been stopped."
        }
    }
}

private struct WAI3DataStatusBanner: View {
    let syncState: WAIProtectedDataSyncState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(label)
                .font(.caption)
                .fontWeight(.semibold)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 34)
        .background(background)
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch syncState {
        case .current:
            return "checkmark.circle"
        case .offline:
            return "wifi.slash"
        case .refreshDeferred:
            return "arrow.clockwise.circle"
        case .remoteRejected:
            return "checkmark.shield"
        }
    }

    private var label: String {
        switch syncState {
        case .current:
            return "Operational data current"
        case .offline:
            return "Offline - using verified data"
        case .refreshDeferred:
            return "Update check unavailable - using verified data"
        case .remoteRejected:
            return "Update not applied - using verified data"
        }
    }

    private var foreground: Color {
        syncState == .offline ? .primary : .orange
    }

    private var background: Color {
        syncState == .offline
            ? Color(.secondarySystemBackground)
            : .orange.opacity(0.12)
    }
}

private struct WAI3ProgressView: View {
    let message: String

    var body: some View {
        VStack(spacing: 0) {
            WAI3BrandHeader()
            Spacer()
            ProgressView(message)
                .controlSize(.large)
            Spacer()
        }
        .background(Color(.systemBackground))
    }
}

private struct WAI3StatusScreen<Actions: View>: View {
    let icon: String
    let title: String
    let message: String
    @ViewBuilder let actions: Actions

    init(
        icon: String,
        title: String,
        message: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 0) {
            WAI3BrandHeader()

            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        Spacer(minLength: 32)

                        VStack(spacing: 16) {
                            Image(systemName: icon)
                                .font(.system(size: 42, weight: .medium))
                                .foregroundStyle(.blue)
                                .accessibilityHidden(true)

                            Text(title)
                                .font(.title2)
                                .fontWeight(.semibold)
                                .multilineTextAlignment(.center)

                            Text(message)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 380)

                            actions
                        }
                        .padding(.horizontal, 24)

                        Spacer(minLength: 32)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .background(Color(.systemBackground))
    }
}

private struct WAI3BrandHeader: View {
    var body: some View {
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
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
