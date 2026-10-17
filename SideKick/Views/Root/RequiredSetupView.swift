import SwiftUI
import Observation
import SideSign
import UserNotifications
import UniformTypeIdentifiers
import UIKit
import Minimuxer

@MainActor
@Observable
final class SetupStatus {
    let accounts = SigningAccountStore()
    private(set) var notificationsEnabled = false
    private(set) var backgroundRefreshEnabled = false
    private(set) var backgroundRefreshRestricted = false
    private(set) var vpnAuthorized = false
    private(set) var pairingVerified = false
    private(set) var isRefreshing = false
    private(set) var isRequestingNotifications = false
    private(set) var isImportingPairing = false
    private(set) var isAuthorizingVPN = false
    private(set) var isCheckingPairing = false
    private(set) var isReady = UserDefaults.standard.bool(forKey: "sidekick.setup.completed")
    var message: String?

    var isBusy: Bool {
        isRefreshing || isRequestingNotifications || isImportingPairing ||
            isAuthorizingVPN || isCheckingPairing || accounts.isWorking
    }

    var hasPairingFile: Bool {
        PairingFileManager.shared.hasPairingFile()
    }

    private var requiredTeamIdentifier: String? {
        ALTApplication(fileURL: Bundle.Info.activeBundleURL)?.provisioningProfile?.teamIdentifier
    }

    var selfSigningAccount: SigningAccountSummary? {
        accounts.accounts.first { $0.hasSavedSession && $0.rawTeamType != nil && $0.teamIdentifier == requiredTeamIdentifier }
    }

    var isDeviceReady: Bool {
        vpnAuthorized && pairingVerified && selfSigningAccount != nil
    }

    func refresh(reportConnectionErrors: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        message = nil
        let notificationSettings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsEnabled = notificationSettings.authorizationStatus == .authorized
        let refreshStatus = UIApplication.shared.backgroundRefreshStatus
        backgroundRefreshEnabled = refreshStatus == .available
        backgroundRefreshRestricted = refreshStatus == .restricted
        await LocalVPNService.shared.refreshStatus()
        vpnAuthorized = LocalVPNService.shared.isConnectionReady
        await accounts.reload()

        guard vpnAuthorized, selfSigningAccount != nil else {
            pairingVerified = false
            updateReadyState()
            return
        }

        let hasPairingFile = PairingFileManager.shared.hasPairingFile()
        if hasPairingFile && UserDefaults.standard.bool(forKey: Self.pairingVerifiedKey) {
            pairingVerified = true
            updateReadyState()
            return
        }
        guard hasPairingFile else {
            pairingVerified = false
            updateReadyState()
            return
        }

        guard reportConnectionErrors, !isCheckingPairing else { updateReadyState(); return }
        isCheckingPairing = true
        defer { isCheckingPairing = false }
        do {
            guard PairingFileManager.shared.fetchPairingFile() != nil else {
                pairingVerified = false
                updateReadyState()
                return
            }
            let vpnLease = try await LocalVPNService.shared.acquire()
            defer { LocalVPNService.shared.release(vpnLease) }
            _ = try await fetchUDID(forceLive: true)
            pairingVerified = true
            UserDefaults.standard.set(true, forKey: Self.pairingVerifiedKey)
        } catch {
            pairingVerified = false
            if reportConnectionErrors {
                message = "SideKick couldn’t verify the iPhone connection: \(error.localizedDescription)"
            }
        }
        updateReadyState()
    }

    private static let pairingVerifiedKey = "sidekick.setup.pairing-verified"
    func updateReadyState() {
        isReady = UserDefaults.standard.bool(forKey: "sidekick.setup.completed")
    }

    func completeSetup() async {
        await refresh()
        UserDefaults.standard.set(true, forKey: "sidekick.setup.completed")
        updateReadyState()
    }

    func requestNotifications() async {
        guard !isRequestingNotifications else { return }
        isRequestingNotifications = true
        defer { isRequestingNotifications = false }
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            message = error.localizedDescription
        }
        await refresh()
    }

    func importPairingFile(from url: URL) async {
        guard !isImportingPairing else { return }
        isImportingPairing = true
        defer { isImportingPairing = false }
        do {
            UserDefaults.standard.set(false, forKey: Self.pairingVerifiedKey)
            try PairingSetupImporter.importFile(from: url)
            await refresh(reportConnectionErrors: true)
            if vpnAuthorized && selfSigningAccount != nil && !pairingVerified && message == nil {
                message = "The pairing file was imported, but SideKick couldn’t verify it. Check that it was made for this iPhone."
            }
        } catch {
            message = "Couldn’t import that pairing file: \(error.localizedDescription)"
        }
    }

    func authorizeLocalConnection() async {
        guard !isAuthorizingVPN else { return }
        isAuthorizingVPN = true
        defer { isAuthorizingVPN = false }
        do {
            try await LocalVPNService.shared.authorize()
            await refresh(reportConnectionErrors: true)
        } catch { message = error.localizedDescription }
    }

    func verifyPairing() async {
        await refresh(reportConnectionErrors: true)
        if !pairingVerified, message == nil {
            let vpn = LocalVPNService.shared
            if vpn.mode == .external {
                let action = vpn.externalInstalled ? "Connect LocalDevVPN" : "Get LocalDevVPN"
                message = "Choose \(action), return here, then choose Verify This iPhone."
            } else if vpn.isConfigured {
                message = "Choose Verify This iPhone again."
            } else {
                message = "Choose Allow Built-in VPN, then choose Verify This iPhone."
            }
        }
    }
}

struct RequiredSetupView: View {
    @Bindable var status: SetupStatus
    @State private var isChoosingPairingFile = false
    @State private var isShowingSignIn = false
    @State private var credentials: (appleID: String, password: String)?
    @AppStorage("sidekick.setup.step") private var step = 0

    private let lastStep = 3

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("STEP \(step + 1) OF \(lastStep + 1)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(step + 1), total: Double(lastStep + 1))
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)

                Group {
                    switch step {
                    case 0: welcomePage
                    case 1: accountPage
                    case 2: pairingPage
                    default: vpnPage
                    }
                }
                .id(step)
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: 12) {
                    SwiftUI.Button {
                        if step == lastStep {
                            Task { await status.completeSetup() }
                        } else {
                            withAnimation(.easeInOut(duration: 0.2)) { step += 1 }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            if status.isBusy { ProgressView() }
                            Text(step == 0 ? "Get Started" : step == lastStep ? "Finish Setup" : "Continue")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .primaryActionStyle()
                    .disabled(status.isBusy)
                }
                .frame(maxWidth: 500)
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity)
                .floatingBarBackground()
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("SideKick Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if step > 0 {
                    ToolbarItem(placement: .topBarLeading) {
                        SwiftUI.Button {
                            withAnimation(.easeInOut(duration: 0.2)) { step -= 1 }
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .accessibilityLabel("Back")
                        .disabled(status.isBusy)
                    }
                }
            }
            .fileImporter(
                isPresented: $isChoosingPairingFile,
                allowedContentTypes: PairingFileManager.supportedContentTypes,
                allowsMultipleSelection: false
            ) { result in
                Task {
                    do {
                        if let url = try result.get().first { await status.importPairingFile(from: url) }
                    } catch {
                        status.message = error.localizedDescription
                    }
                }
            }
            .onChange(of: LocalVPNService.shared.preferredMode) { _, _ in
                Task { await status.refresh() }
            }
            .onAppear { step = min(max(step, 0), lastStep) }
            .sheet(isPresented: $isShowingSignIn, onDismiss: finishSignIn) {
                AppleIDSignInSheet { appleID, password in credentials = (appleID, password) }
            }
            .alert("Setup", isPresented: Binding(
                get: { status.message != nil },
                set: { if !$0 { status.message = nil } }
            )) {
                SwiftUI.Button("OK", role: .cancel) { status.message = nil }
            } message: {
                Text(status.message ?? "")
            }
        }
    }

    private var welcomePage: some View {
        onboardingPage(
            symbol: "square.stack.3d.up.fill",
            title: "Welcome to SideKick",
            message: "Set up an Apple Account and a connection to this iPhone. You can finish now and add anything you skip when you need it."
        )
    }

    private var accountPage: some View {
        onboardingPage(
            symbol: "person.crop.circle",
            title: "Choose a signing account",
            message: "Add the Apple Account that signed SideKick. You can add it later if you’re not ready to sign in now."
        ) {
            if let account = status.selfSigningAccount {
                Label(account.email, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if status.accounts.isWorking {
                ProgressView("Signing in to Apple…")
                    .frame(maxWidth: .infinity, minHeight: 52)
            } else {
                SwiftUI.Button("Add Apple Account") { isShowingSignIn = true }
                    .secondaryActionStyle()
                .tint(.sideKickAccent)
                    .disabled(status.isBusy)
                if !status.accounts.accounts.isEmpty {
                    Text("Use the Apple Account that signed this copy of SideKick.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var pairingPage: some View {
        onboardingPage(
            symbol: "iphone.gen3.radiowaves.left.and.right",
            title: "Pair this iPhone",
            message: status.hasPairingFile
                ? "Pairing file imported. You can verify the connection now or when you first install or refresh an app."
                : "A pairing file lets SideKick connect to this iPhone for installs and refreshes. You can import one now or later. Keep the file private."
        ) {
            SwiftUI.Button(status.hasPairingFile ? "Choose Pairing File Again" : "Import Pairing File") {
                isChoosingPairingFile = true
            }
            .secondaryActionStyle()
                .tint(.sideKickAccent)
            .disabled(status.isBusy)
            if status.isImportingPairing { ProgressView("Importing pairing file…") }
            Link("How to create a pairing file", destination: AppConstants.URLs.pairingDocumentation)
                .font(.subheadline)
        }
    }

    private var vpnPage: some View {
        onboardingPage(
            symbol: "network.badge.shield.half.filled",
            title: "Connect to this iPhone",
            message: LocalVPNService.shared.mode == .external
                ? "Connect LocalDevVPN before verifying or installing apps. Disconnect it in LocalDevVPN when you finish."
                : "Allow SideKick’s local VPN for installs and refreshes. It connects for each operation and disconnects afterward."
        ) {
            if LocalVPNService.shared.mode == .external {
                SwiftUI.Button {
                    let vpn = LocalVPNService.shared
                    UIApplication.shared.open(vpn.externalInstalled ? LocalVPNService.externalURL : LocalVPNService.externalStoreURL)
                } label: {
                    Label(LocalVPNService.shared.externalInstalled ? "Connect LocalDevVPN" : "Get LocalDevVPN", systemImage: "arrow.up.forward.app")
                }
                .secondaryActionStyle()
                .tint(.sideKickAccent)
                .disabled(status.isBusy)
                Label(LocalVPNService.shared.externalTunnelConnected ? "Local Tunnel Connected" : "Connect Before Verifying",
                    systemImage: LocalVPNService.shared.externalTunnelConnected ? "checkmark.circle.fill" : "network.slash")
                    .foregroundStyle(.secondary)
            } else if !LocalVPNService.shared.isConfigured {
                SwiftUI.Button { Task { await status.authorizeLocalConnection() } } label: {
                    Label("Allow Built-in VPN", systemImage: "checkmark.shield")
                }
                .secondaryActionStyle()
                .tint(.sideKickAccent)
                .disabled(status.isBusy)
            } else {
                Label("VPN Permission Saved", systemImage: "checkmark.shield.fill").foregroundStyle(.green)
            }
            NavigationLink { LocalConnectionModeView() } label: {
                Label("Connection Method", systemImage: "network")
            }.disabled(status.isBusy)
            if status.isAuthorizingVPN || status.isCheckingPairing {
                ProgressView(status.isCheckingPairing ? "Verifying this iPhone…" : "Saving VPN permission…")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            if status.vpnAuthorized && status.hasPairingFile && !status.pairingVerified {
                SwiftUI.Button { Task { await status.verifyPairing() } } label: {
                    Label("Verify This iPhone", systemImage: "iphone.gen3.radiowaves.left.and.right")
                }
                .secondaryActionStyle()
                .tint(.sideKickAccent)
                .disabled(status.isBusy)
            }
            if status.isDeviceReady {
                Label("iPhone Verified", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
    }

    private func onboardingPage<Actions: View>(
        symbol: String,
        title: String,
        message: String,
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) -> some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 20) {
                    Image(systemName: symbol)
                        .font(.largeTitle.weight(.regular))
                        .imageScale(.large)
                        .foregroundStyle(.tint)
                        .frame(height: 84)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.largeTitle.weight(.bold))
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text(message)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 18, content: actions)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .padding(step == 0 ? 0 : 24)
                    .background {
                        if step != 0 {
                            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground))
                        }
                    }
            }
            .frame(maxWidth: 500)
            .padding(.horizontal, 24)
            .padding(.top, 36)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func finishSignIn() {
        guard let credentials else { return }
        self.credentials = nil
        Task {
            do {
                try await status.accounts.addAccount(appleID: credentials.appleID, password: credentials.password)
                await status.refresh()
            } catch {
                status.message = error.localizedDescription
            }
        }
    }
}
