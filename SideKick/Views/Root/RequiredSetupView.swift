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
    private(set) var refreshAutomationsConfigured = UserDefaults.standard.bool(forKey: "sidekick.setup.refresh-automations-configured")
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
    private static let refreshAutomationsConfiguredKey = "sidekick.setup.refresh-automations-configured"

    func confirmRefreshAutomationsConfigured() {
        refreshAutomationsConfigured = true
        UserDefaults.standard.set(true, forKey: Self.refreshAutomationsConfiguredKey)
        updateReadyState()
    }

    func updateReadyState() {
        isReady = UserDefaults.standard.bool(forKey: "sidekick.setup.completed")
    }

    func completeSetup() async {
        await refresh()
        guard isDeviceReady && refreshAutomationsConfigured else {
            message = "Finish the signing account, pairing, local connection and shortcut steps first."
            return
        }
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
            message = LocalVPNService.shared.mode == .external ? "Connect LocalDevVPN, return here, then verify this iPhone." : "Allow SideKick’s built-in VPN, then verify the pairing file again."
        }
    }
}

struct RequiredSetupView: View {
    @Bindable var status: SetupStatus
    @State private var isChoosingPairingFile = false
    @State private var isShowingSignIn = false
    @State private var credentials: (appleID: String, password: String)?
    @AppStorage("sidekick.setup.step") private var step = 0

    private let lastStep = 6

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
                    case 1: notificationsPage
                    case 2: backgroundRefreshPage
                    case 3: accountPage
                    case 4: pairingPage
                    case 5: vpnPage
                    default: refreshAutomationPage
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
                            if status.isBusy { ProgressView().tint(.white) }
                            Text(step == 0 ? "Get Started" : step == lastStep ? "Finish Setup" : "Continue")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canContinue || status.isBusy)
                    if (step == 1 && !status.notificationsEnabled) || (step == 2 && !status.backgroundRefreshEnabled) {
                        SwiftUI.Button("Not Now") {
                            withAnimation(.easeInOut(duration: 0.2)) { step += 1 }
                        }
                        .frame(minHeight: 44)
                        .disabled(status.isBusy)
                    }
                }
                .frame(maxWidth: 500)
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 20)
                .background(.bar)
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

    private var canContinue: Bool {
        switch step {
        case 0: true
        case 1: status.notificationsEnabled
        case 2: status.backgroundRefreshEnabled
        case 3: status.selfSigningAccount != nil
        case 4: status.hasPairingFile
        case 5: status.isDeviceReady
        case 6: status.refreshAutomationsConfigured
        default: false
        }
    }

    private var welcomePage: some View {
        onboardingPage(
            symbol: "square.stack.3d.up.fill",
            title: "Welcome to SideKick",
            message: "A few quick steps prepare this iPhone to install and refresh your apps. You can change these choices later in Settings."
        )
    }

    private var notificationsPage: some View {
        onboardingPage(
            symbol: "bell.badge",
            title: "Stay up to date",
            message: "Get reminders before apps expire and notifications when a scheduled check finds a GitHub update. You can enable notifications later in Settings."
        ) {
            SwiftUI.Button(status.notificationsEnabled ? "Notifications Allowed" : "Allow Notifications") {
                Task {
                    await status.requestNotifications()
                    if !status.notificationsEnabled {
                        await UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(status.notificationsEnabled || status.isBusy)
        }
    }

    private var backgroundRefreshPage: some View {
        onboardingPage(
            symbol: "arrow.clockwise",
            title: "Keep apps refreshed",
            message: status.backgroundRefreshRestricted
                ? "iOS currently restricts Background App Refresh on this device. SideKick can’t change this system setting."
                : "Allow Background App Refresh so SideKick can check signing status and help keep your apps available."
        ) {
            if status.backgroundRefreshEnabled {
                Label("Background App Refresh is On", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if !status.backgroundRefreshRestricted {
                SwiftUI.Button("Open Settings") {
                    UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var accountPage: some View {
        onboardingPage(
            symbol: "person.crop.circle",
            title: "Choose a signing account",
            message: "SideKick uses the Apple Account that signed this copy of SideKick to refresh it. You’ll choose an account for each app you install."
        ) {
            if let account = status.selfSigningAccount {
                Label(account.email, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if status.accounts.isWorking {
                ProgressView("Signing in to Apple…")
                    .frame(maxWidth: .infinity, minHeight: 52)
            } else {
                SwiftUI.Button("Add Apple Account") { isShowingSignIn = true }
                    .buttonStyle(.borderedProminent)
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
                ? "Pairing file imported. Next, connect to this iPhone using your chosen connection method."
                : "iLoader can’t place the file because SideKick isn’t in its supported-app list yet. In iLoader choose Export, then AirDrop the file to this iPhone or save it in Files and import it here. Pairing files are sensitive; keep the transfer private."
        ) {
            SwiftUI.Button(status.hasPairingFile ? "Choose Pairing File Again" : "Import Pairing File") {
                isChoosingPairingFile = true
            }
            .buttonStyle(.borderedProminent)
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
                ? "Connect LocalDevVPN, then return here to verify this iPhone. This works with free Apple Accounts. SideKick cannot disconnect another app’s VPN; turn it off in LocalDevVPN when finished."
                : "Allow SideKick’s built-in VPN once. It connects for device operations and disconnects when they finish. Your internet traffic stays on its regular connection."
        ) {
            if LocalVPNService.shared.mode == .external {
                SwiftUI.Button {
                    let vpn = LocalVPNService.shared
                    UIApplication.shared.open(vpn.externalInstalled ? LocalVPNService.externalURL : LocalVPNService.externalStoreURL)
                } label: {
                    Label(LocalVPNService.shared.externalInstalled ? "Connect LocalDevVPN" : "Get LocalDevVPN", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderedProminent)
                .disabled(status.isBusy)
                Label(LocalVPNService.shared.externalTunnelConnected ? "Local Tunnel Connected" : "Connect Before Verifying",
                    systemImage: LocalVPNService.shared.externalTunnelConnected ? "checkmark.circle.fill" : "network.slash")
                    .foregroundStyle(.secondary)
            } else if !LocalVPNService.shared.isConfigured {
                SwiftUI.Button { Task { await status.authorizeLocalConnection() } } label: {
                    Label("Allow Built-in VPN", systemImage: "checkmark.shield")
                }
                .buttonStyle(.borderedProminent)
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
                .buttonStyle(.borderedProminent)
                .disabled(status.isBusy)
            }
            if status.isDeviceReady {
                Label("iPhone Verified", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
    }

    private var refreshAutomationPage: some View {
        onboardingPage(
            symbol: "clock.arrow.circlepath",
            title: "Add the refresh shortcut",
            message: "Add the shortcut, then create a daily automation in Shortcuts using Run Immediately. Each run checks GitHub for new versions and refreshes your apps. iOS controls whether background work can run.") {
            VStack(spacing: 12) {
                Link("Get Shortcut", destination: URL(string: "https://www.icloud.com/shortcuts/2af57f665d434568a589f1e9b7d7f4d1")!)
                .buttonStyle(.borderedProminent)

                SwiftUI.Button {
                    status.confirmRefreshAutomationsConfigured()
                } label: {
                    Label(status.refreshAutomationsConfigured ? "Shortcut Added" : "I’ve Added the Shortcut",
                          systemImage: status.refreshAutomationsConfigured ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .buttonStyle(.bordered)
                .disabled(status.refreshAutomationsConfigured)
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
                        .font(.system(size: 56, weight: .regular))
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
                            RoundedRectangle(cornerRadius: 24).fill(Color(uiColor: .secondarySystemGroupedBackground))
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
