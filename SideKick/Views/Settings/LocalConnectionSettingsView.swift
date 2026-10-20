import SwiftUI

struct LocalConnectionSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var vpn = LocalVPNService.shared
    @State private var isWorking = false
    @State private var message: String?
    @State private var showingMessage = false
    @State private var lastVerification: Date?
    @State private var hasPairingFile = PairingFileManager.shared.hasPairingFile()
    @AppStorage("sidekick.setup.pairing-verified") private var pairingVerified = false

    private var isReady: Bool { hasPairingFile && vpn.isConnectionReady && pairingVerified }

    var body: some View {
        Form {
            Section {
                VStack(spacing: Spacing.s) {
                    StatusSymbol(systemImage: isReady ? "checkmark" : "network", tone: isReady ? .success : .warning)
                    Text(isReady ? "Ready to Install" : "Finish Connection Setup")
                        .font(.title2.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    Text(isReady
                         ? "SideKick can reach this iPhone to install and refresh apps."
                         : "SideKick needs a pairing file and a local connection to install apps.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.xs)
            }
            .listRowBackground(Color.clear)

            Section {
                NavigationLink { ConnectionSettingsView() } label: {
                    ChecklistRow(title: "Pairing File", detail: hasPairingFile ? "Imported" : "Not set up", isDone: hasPairingFile)
                }

                SwiftUI.Button {
                    UIApplication.shared.open(vpn.externalInstalled ? LocalVPNService.externalURL : LocalVPNService.externalStoreURL)
                } label: {
                    ChecklistRow(
                        title: "LocalDevVPN",
                        detail: vpn.externalTunnelConnected ? "Connected" : (vpn.externalInstalled ? "Tap to connect" : "Tap to get from the App Store"),
                        isDone: vpn.externalTunnelConnected
                    )
                }
                .disabled(isWorking || vpn.isBusy)

                ChecklistRow(
                    title: "iPhone Verified",
                    detail: lastVerification.map { "Checked \($0.formatted(.relative(presentation: .named)))" }
                        ?? (pairingVerified ? "Verified" : "Not checked yet"),
                    isDone: pairingVerified
                )
            } header: {
                Text("Setup")
            } footer: {
                Text("Disconnect LocalDevVPN in its own app when you’re done.")
            }

            Section {
                NavigationLink { HealthCheckView(readyTitle: "SideKick Ready") } label: {
                    Label("Health Check", systemImage: "stethoscope")
                }
                NavigationLink { LocalConnectionHelpView() } label: {
                    Label("How Connections Work", systemImage: "questionmark.circle")
                }
            }

            Section {
                DisclosureGroup("Details") {
                    LabeledContent("Status", value: vpn.statusLabel)
                    Link("LocalDevVPN Source & Credits", destination: URL(string: "https://github.com/seomin0610/LocalDevVPN")!)
                }
            } footer: {
                Text("LocalDevVPN is made by Stossy11, Magesh K and the SideStore Team.")
            }
        }
        .safeAreaInset(edge: .bottom) {
            BottomActionBar {
                SwiftUI.Button { Task { await verify() } } label: {
                    ActionLabel(isWorking ? "Checking…" : "Verify Connection", systemImage: "iphone.gen3.radiowaves.left.and.right", isWorking: isWorking)
                }
                .primaryActionStyle()
                .disabled(isWorking || vpn.isBusy || !vpn.isConnectionReady || !hasPairingFile)
                if vpn.isBusy {
                    Text("An install or refresh is using the connection.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
        .refreshable { await refresh() }
        .alert("Connection", isPresented: $showingMessage) {
            SwiftUI.Button("OK", role: .cancel) { }
        } message: { Text(message ?? "") }
    }

    @MainActor private func refresh() async {
        await vpn.refreshStatus()
        hasPairingFile = PairingFileManager.shared.hasPairingFile()
    }

    @MainActor private func verify() async {
        isWorking = true
        defer { isWorking = false }
        do {
            guard PairingFileManager.shared.fetchPairingFile() != nil else { throw PairingSetupErrorForVPN.missing }
            try await vpn.withConnection {
                _ = try await fetchUDID(forceLive: true)
            }
            lastVerification = .now
            pairingVerified = true
            message = "This iPhone is reachable. LocalDevVPN stays connected."
        } catch { message = error.localizedDescription }
        showingMessage = true
    }
}

/// A setup step with a clear done/not-done state. Used by Connection and onboarding.
struct ChecklistRow: View {
    let title: String
    let detail: String
    let isDone: Bool

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title3)
                .foregroundStyle(isDone ? Color.green : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isDone ? "Done" : "Not done")
    }
}

private enum PairingSetupErrorForVPN: LocalizedError {
    case missing
    var errorDescription: String? { "Import a pairing file for this iPhone in Settings → Connection → Pairing File, then verify again." }
}

private struct LocalConnectionHelpView: View {
    @State private var vpn = LocalVPNService.shared

    var body: some View {
        List {
            Section {
                Label("Free Apple Accounts", systemImage: "person.crop.circle")
                Text("Use the standard SideKick IPA and LocalDevVPN from the App Store. Connect LocalDevVPN before installing, refreshing or enabling JIT. SideKick cannot control or disconnect another app’s tunnel.")
            } header: { Text("LocalDevVPN") }
            Section {
                Label("Connect LocalDevVPN", systemImage: "arrow.up.forward.app")
                Text("Connect LocalDevVPN before checking the pairing file. The tunnel is managed in LocalDevVPN and doesn’t need VPN permission in SideKick.")
            } header: { Text("Local Connection") }
            Section {
                Label("Automatic disconnection", systemImage: "clock.badge.checkmark")
                Text("SideKick shares one connection across overlapping operations. LocalDevVPN stays connected until you turn it off in that app. iOS may suspend background work, so a scheduled refresh can fail and retry later.")
            } header: { Text("Operation Lifetime") }
        }
        .navigationTitle("How Connections Work")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vpn.refreshStatus() }
    }

}
