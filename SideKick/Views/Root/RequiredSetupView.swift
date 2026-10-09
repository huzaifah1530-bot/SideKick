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
    private(set) var vpnInstalled = false
    private(set) var vpnConnected = false
    private(set) var pairingVerified = false
    private(set) var refreshAutomationsConfigured = UserDefaults.standard.bool(forKey: "sidekick.setup.refresh-automations-configured")
    private(set) var isCheckingPairing = false
    private(set) var isReady = false
    var message: String?

    var hasPairingFile: Bool {
        PairingFileManager.shared.hasPairingFile()
    }

    private var requiredTeamIdentifier: String? {
        ALTApplication(fileURL: Bundle.Info.activeBundleURL)?.provisioningProfile?.teamIdentifier
    }

    var selfSigningAccount: SigningAccountSummary? {
        accounts.accounts.first { $0.hasSavedSession && $0.teamIdentifier == requiredTeamIdentifier }
    }

    var isDeviceReady: Bool {
        notificationsEnabled && backgroundRefreshEnabled && vpnInstalled && pairingVerified &&
            vpnConnected && selfSigningAccount != nil
    }

    func refresh(reportConnectionErrors: Bool = false) async {
        message = nil
        let notificationSettings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsEnabled = notificationSettings.authorizationStatus == .authorized
        let refreshStatus = UIApplication.shared.backgroundRefreshStatus
        backgroundRefreshEnabled = refreshStatus == .available
        backgroundRefreshRestricted = refreshStatus == .restricted
        vpnInstalled = UIApplication.shared.canOpenURL(URL(string: "localdevvpn://")!)
        vpnConnected = Minimuxer.shared.network.activeInterfaces.contains { interface in
            interface.name.lowercased().hasPrefix("utun") && interface.ip.hasPrefix("10.7.")
        }
        await accounts.reload()

        guard notificationsEnabled, backgroundRefreshEnabled, vpnInstalled, selfSigningAccount != nil else {
            pairingVerified = false
            updateReadyState()
            return
        }

        guard vpnConnected else {
            pairingVerified = false
            updateReadyState()
            if reportConnectionErrors {
                message = "LocalDevVPN is installed, but SideKick can’t detect its connected tunnel. Open LocalDevVPN, connect it, then try again."
            }
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

        isCheckingPairing = true
        defer { isCheckingPairing = false }
        do {
            guard let contents = PairingFileManager.shared.fetchPairingFile() else {
                pairingVerified = false
                updateReadyState()
                return
            }
            try await AppBootManager.shared.startMinimuxer(pairingFile: contents)
            try await ensureMinimuxerReady()
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
        isReady = isDeviceReady && refreshAutomationsConfigured
    }

    func requestNotifications() async {
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            message = error.localizedDescription
        }
        await refresh()
    }

    func importPairingFile(from url: URL) async {
        do {
            UserDefaults.standard.set(false, forKey: Self.pairingVerifiedKey)
            try PairingSetupImporter.importFile(from: url)
            await refresh(reportConnectionErrors: true)
            if notificationsEnabled && backgroundRefreshEnabled && vpnInstalled && selfSigningAccount != nil && vpnConnected && !pairingVerified && message == nil {
                message = "The pairing file was imported, but SideKick couldn’t verify it. Check that it was made for this iPhone."
            }
        } catch {
            message = "Couldn’t import that pairing file: \(error.localizedDescription)"
        }
    }

    func verifyPairing() async {
        await refresh(reportConnectionErrors: true)
        if !pairingVerified, message == nil {
            message = "Pairing is not ready. Connect LocalDevVPN and try again."
        }
    }
}

struct RequiredSetupView: View {
    @Bindable var status: SetupStatus
    @State private var isChoosingPairingFile = false
    @State private var isShowingSignIn = false
    @State private var credentials: (appleID: String, password: String)?
    @State private var step = 0

    private let vpnURL = URL(string: "localdevvpn://enable?scheme=sidestore")!
    private let appStoreURL = URL(string: "https://apps.apple.com/app/id6755608044")!
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

                TabView(selection: $step) {
                    welcomePage.tag(0)
                    notificationsPage.tag(1)
                    backgroundRefreshPage.tag(2)
                    accountPage.tag(3)
                    pairingPage.tag(4)
                    vpnPage.tag(5)
                    refreshAutomationPage.tag(6)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                SwiftUI.Button(step == lastStep ? "Finish Setup" : "Continue") {
                    if step == lastStep {
                        Task { await status.refresh() }
                    } else {
                        withAnimation(.easeInOut(duration: 0.2)) { step += 1 }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(!canContinue)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
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
            message: "Notifications let SideKick tell you when an app needs attention or is nearing its refresh date."
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
            .disabled(status.notificationsEnabled)
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
            } else {
                SwiftUI.Button("Add Apple Account") { isShowingSignIn = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var pairingPage: some View {
        onboardingPage(
            symbol: "iphone.gen3.radiowaves.left.and.right",
            title: "Pair this iPhone",
            message: status.hasPairingFile
                ? "Pairing file imported. Next, connect through LocalDevVPN to verify this iPhone."
                : "iLoader can’t place the file because SideKick isn’t in its supported-app list yet. In iLoader choose Export, then AirDrop the file to this iPhone or save it in Files and import it here. Pairing files are sensitive; keep the transfer private."
        ) {
            SwiftUI.Button(status.hasPairingFile ? "Choose Pairing File Again" : "Import Pairing File") {
                isChoosingPairingFile = true
            }
            .buttonStyle(.borderedProminent)
            Link("How to create a pairing file", destination: AppConstants.URLs.pairingDocumentation)
                .font(.subheadline)
        }
    }

    private var vpnPage: some View {
        onboardingPage(
            symbol: "network",
            title: "Connect to this iPhone",
            message: status.isDeviceReady
                ? "Your iPhone is paired and ready."
                : status.vpnConnected
                    ? "LocalDevVPN’s tunnel is connected. Verify that this pairing file belongs to this iPhone."
                    : "SideKick doesn’t currently detect LocalDevVPN’s connected tunnel. Open LocalDevVPN, connect it, return here, then verify."
        ) {
            SwiftUI.Button(status.vpnInstalled ? "Open LocalDevVPN" : "Get LocalDevVPN") {
                UIApplication.shared.open(status.vpnInstalled ? vpnURL : appStoreURL)
            }
            .buttonStyle(.borderedProminent)

            Label(status.vpnConnected ? "VPN Connected" : "VPN Not Detected", systemImage: status.vpnConnected ? "checkmark.circle.fill" : "network.slash")
                .font(.subheadline)
                .foregroundStyle(status.vpnConnected ? .green : .secondary)

            if status.vpnInstalled && status.hasPairingFile && !status.isReady {
                SwiftUI.Button(status.isCheckingPairing ? "Checking…" : "Verify Connection") {
                    Task { await status.verifyPairing() }
                }
                .disabled(status.isCheckingPairing)
            }
            if status.isDeviceReady {
                Label("Setup Complete", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    private var refreshAutomationPage: some View {
        onboardingPage(
            symbol: "clock.arrow.circlepath",
            title: "Schedule app refreshes",
            message: "Add two daily Personal Automations in Shortcuts: run SideKick’s “Refresh Apps” action at 2:00 AM and again at 8:00 PM. The evening run skips if the morning refresh succeeded. Missed attempts stay quiet; SideKick only notifies you when an app has about two days left.") {
            VStack(spacing: 12) {
                SwiftUI.Button("Open Shortcuts") {
                    UIApplication.shared.open(URL(string: "shortcuts://")!)
                }
                .buttonStyle(.borderedProminent)

                Text("In Shortcuts, create a Time of Day automation for each time, choose Daily, add the “Refresh SideKick Apps” action, and turn off Ask Before Running. iOS does not let apps create or verify personal automations for you.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                SwiftUI.Button {
                    status.confirmRefreshAutomationsConfigured()
                } label: {
                    Label(status.refreshAutomationsConfigured ? "Automations Added" : "I’ve Added Both Automations",
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
        VStack(spacing: 22) {
            Spacer(minLength: 12)
            Image(systemName: symbol)
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(.tint)
                .frame(height: 64)
                .accessibilityHidden(true)
            Text(title)
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 16, content: actions)
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
