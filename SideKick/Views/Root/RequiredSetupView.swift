import SwiftUI
import Observation
import SideSign
import UserNotifications
import UniformTypeIdentifiers
import UIKit

@MainActor
@Observable
final class SetupStatus {
    let accounts = SigningAccountStore()
    private(set) var notificationsEnabled = false
    private(set) var backgroundRefreshEnabled = false
    private(set) var backgroundRefreshRestricted = false
    private(set) var vpnInstalled = false
    private(set) var pairingVerified = false
    private(set) var isCheckingPairing = false
    private(set) var isReady = false
    var message: String?

    private var requiredTeamIdentifier: String? {
        ALTApplication(fileURL: Bundle.Info.activeBundleURL)?.provisioningProfile?.teamIdentifier
    }

    var selfSigningAccount: SigningAccountSummary? {
        accounts.accounts.first { $0.hasSavedSession && $0.teamIdentifier == requiredTeamIdentifier }
    }

    func refresh() async {
        let notificationSettings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsEnabled = notificationSettings.authorizationStatus == .authorized
        let refreshStatus = UIApplication.shared.backgroundRefreshStatus
        backgroundRefreshEnabled = refreshStatus == .available
        backgroundRefreshRestricted = refreshStatus == .restricted
        vpnInstalled = UIApplication.shared.canOpenURL(URL(string: "localdevvpn://")!)
        await accounts.reload()

        guard notificationsEnabled, backgroundRefreshEnabled, vpnInstalled, selfSigningAccount != nil else {
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
            message = "SideKick can’t reach this iPhone yet. Connect LocalDevVPN, then check again."
        }
        updateReadyState()
    }

    private static let pairingVerifiedKey = "sidekick.setup.pairing-verified"

    func updateReadyState() {
        isReady = notificationsEnabled && backgroundRefreshEnabled && vpnInstalled && pairingVerified &&
            selfSigningAccount != nil
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
            try PairingFileManager.shared.importPairingFile(from: url)
            await refresh()
            if !pairingVerified {
                message = "Pairing file was imported, but verification failed. Make sure LocalDevVPN is connected and that the file belongs to this iPhone."
            }
        } catch {
            message = "Couldn’t import that pairing file: \(error.localizedDescription)"
        }
    }

    func verifyPairing() async {
        await refresh()
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

    private let vpnURL = URL(string: "localdevvpn://enable?scheme=sidestore")!
    private let appStoreURL = URL(string: "https://apps.apple.com/app/id6755608044")!

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Set up SideKick")
                            .font(.largeTitle.bold())
                        Text("Complete these steps once to install and refresh apps from this iPhone.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 10)
                    .listRowBackground(Color.clear)
                }

                Section("Required") {
                    setupRow(
                        title: "Notifications",
                        detail: status.notificationsEnabled ? "On" : "Allow signing and expiry alerts",
                        symbol: "bell"
                    ) {
                        Task {
                            await status.requestNotifications()
                            if !status.notificationsEnabled {
                                await UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                            }
                        }
                    } label: {
                        status.notificationsEnabled ? "Allowed" : "Allow Notifications"
                    }

                    setupRow(
                        title: "Background App Refresh",
                        detail: status.backgroundRefreshEnabled
                            ? "On"
                            : status.backgroundRefreshRestricted
                                ? "Unavailable because this device restricts background refresh"
                                : "Turn it on in Settings → General → Background App Refresh; Low Power Mode also pauses it",
                        symbol: "arrow.clockwise"
                    ) {
                        if !status.backgroundRefreshRestricted {
                            UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                        }
                    } label: {
                        status.backgroundRefreshEnabled ? "On" : status.backgroundRefreshRestricted ? "Unavailable" : "Open Settings"
                    }
                    .disabled(status.backgroundRefreshRestricted || status.backgroundRefreshEnabled)

                    setupRow(
                        title: "LocalDevVPN",
                        detail: status.vpnInstalled ? "Installed" : "Required to connect to this iPhone’s signing service",
                        symbol: "network"
                    ) {
                        UIApplication.shared.open(status.vpnInstalled ? vpnURL : appStoreURL)
                    } label: {
                        status.vpnInstalled ? "Open LocalDevVPN" : "Get LocalDevVPN"
                    }

                    setupRow(
                        title: "Pair this iPhone",
                        detail: status.isCheckingPairing ? "Checking connection…" : (status.pairingVerified ? "Pairing verified" : "Import the trust file made for this iPhone with iLoader on a computer"),
                        symbol: "iphone.gen3.radiowaves.left.and.right"
                    ) {
                        isChoosingPairingFile = true
                    } label: {
                        status.pairingVerified ? "Verified" : "Import Pairing File"
                    }
                    .disabled(status.isCheckingPairing)

                    Link("How to create a pairing file", destination: AppConstants.URLs.pairingDocumentation)

                    if !status.pairingVerified && status.vpnInstalled && PairingFileManager.shared.hasPairingFile() {
                        SwiftUI.Button {
                            UIApplication.shared.open(vpnURL)
                            Task { try? await Task.sleep(for: .seconds(2)); await status.verifyPairing() }
                        } label: {
                            Label("Connect and Verify", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }

                    setupRow(
                        title: "Apple Account",
                        detail: status.selfSigningAccount?.email ?? "Add the Apple Account used to sign SideKick",
                        symbol: "person.crop.circle"
                    ) {
                        isShowingSignIn = true
                    } label: {
                        status.selfSigningAccount != nil ? "Account Added" : "Add Apple Account"
                    }
                }

                Section {
                    Text("iOS controls notifications and Background App Refresh. SideKick can check these settings and guide you to change them, but it can’t turn them on for you.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    SwiftUI.Button("Check Setup Again") { Task { await status.refresh() } }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Welcome to SideKick")
            .navigationBarTitleDisplayMode(.inline)
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

    private func setupRow(
        title: String,
        detail: String,
        symbol: String,
        action: @escaping () -> Void,
        label: () -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.tint)
                    .frame(width: 26)
                Text(title).font(.body.weight(.medium))
                Spacer()
                SwiftUI.Button(action: action) { Text(label()).font(.subheadline.weight(.semibold)) }
                    .buttonStyle(.borderless)
            }
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.leading, 38)
        }
        .padding(.vertical, 4)
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
