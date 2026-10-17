import SwiftUI

struct LocalConnectionSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var vpn = LocalVPNService.shared
    @State private var isWorking = false
    @State private var message: String?
    @State private var showingMessage = false
    @State private var confirmingRemoval = false
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

                if vpn.mode == .external {
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
                } else {
                    SwiftUI.Button { Task { await authorize() } } label: {
                        ChecklistRow(
                            title: "Built-in VPN",
                            detail: vpn.isConfigured ? "Allowed · connects automatically" : "Tap to allow",
                            isDone: vpn.isConfigured
                        )
                    }
                    .disabled(isWorking || vpn.isBusy || vpn.isConfigured)
                }

                ChecklistRow(
                    title: "iPhone Verified",
                    detail: lastVerification.map { "Checked \($0.formatted(.relative(presentation: .named)))" }
                        ?? (pairingVerified ? "Verified" : "Not checked yet"),
                    isDone: pairingVerified
                )
            } header: {
                Text("Setup")
            } footer: {
                if vpn.mode == .external {
                    Text("Disconnect LocalDevVPN in its own app when you’re done.")
                }
            }

            Section {
                NavigationLink { HealthCheckView(readyTitle: "SideKick Ready") } label: {
                    Label("Health Check", systemImage: "stethoscope")
                }
                NavigationLink { LocalConnectionModeView() } label: {
                    Label { LabeledContent("Connection Method", value: vpn.mode.title) } icon: { Image(systemName: "network") }
                }
                NavigationLink { LocalConnectionHelpView() } label: {
                    Label("How Connections Work", systemImage: "questionmark.circle")
                }
            }

            Section {
                DisclosureGroup("Details") {
                    LabeledContent("Status", value: vpn.statusLabel)
                    LabeledContent("VPN Extension", value: vpn.extensionBundleIdentifier == nil ? "Not included" : "Included")
                    LabeledContent("Built-in VPN Signing", value: vpn.hasSupportedProfiles ? "Supported" : "Not available")
                    Link("LocalDevVPN Source & Credits", destination: URL(string: "https://github.com/seomin0610/LocalDevVPN")!)
                    if vpn.isConfigured {
                        SwiftUI.Button("Remove Built-in VPN Permission", role: .destructive) { confirmingRemoval = true }
                            .disabled(isWorking || vpn.isBusy)
                    }
                }
            } footer: {
                Text("SideKick’s tunnel uses code from LocalDevVPN by Stossy11, Magesh K and the SideStore Team.")
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
        .confirmationDialog("Remove VPN permission?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            SwiftUI.Button("Remove Permission", role: .destructive) {
                Task {
                    do { try await vpn.removeConfiguration() }
                    catch { message = error.localizedDescription; showingMessage = true }
                }
            }
        } message: { Text("SideKick will ask again before its next install or refresh. Your apps and pairing file are kept.") }
    }

    @MainActor private func refresh() async {
        await vpn.refreshStatus()
        hasPairingFile = PairingFileManager.shared.hasPairingFile()
    }

    @MainActor private func authorize() async {
        isWorking = true
        defer { isWorking = false }
        do { try await vpn.authorize() }
        catch { message = error.localizedDescription; showingMessage = true }
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
            message = vpn.mode == .builtIn ? "This iPhone is reachable. The built-in VPN disconnects after this check." : "This iPhone is reachable. LocalDevVPN stays connected."
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
                if vpn.mode == .builtIn {
                    Label("Approve the iOS VPN alert", systemImage: "checkmark.shield")
                    Text("Choose Allow Built-in VPN in SideKick. iOS asks to add a VPN configuration and may require your passcode. This permission is needed once per installation or after removing the configuration.")
                } else {
                    Label("Connect LocalDevVPN", systemImage: "arrow.up.forward.app")
                    Text("Connect LocalDevVPN before checking the pairing file. The external tunnel is managed in LocalDevVPN and does not require SideKick VPN permission.")
                }
            } header: { Text(vpn.mode == .builtIn ? "VPN Permission" : "Local Connection") }
            Section {
                Label("Sign the app and extension", systemImage: "signature")
                Text("Use the optional SideKick-vpn-unsigned IPA and keep SideKickVPN enabled when signing it. Both SideKick and its extension need provisioning profiles containing the Network Extension packet-tunnel-provider capability. Free Apple ID provisioning does not support this capability. Use an eligible Apple Developer signing profile and preserve the extension’s entitlements.")
                Link("Apple Network Extension Documentation", destination: URL(string: "https://developer.apple.com/documentation/networkextension/nepackettunnelprovider")!)
            } header: { Text("Signing Requirements") }
            Section {
                Label("Local traffic stays on this iPhone", systemImage: "iphone")
                Text("Only the local developer peer is routed through the tunnel. SideKick does not configure a default internet route or a remote VPN server. Your normal internet connection remains in use.")
            } header: { Text("Privacy") }
            Section {
                Label("Automatic disconnection", systemImage: "clock.badge.checkmark")
                Text("SideKick shares one connection across overlapping operations and stops it after the last operation completes or fails. Its extension checks for a heartbeat; after 90 seconds without SideKick responding, it closes the tunnel. iOS may suspend background work, so a scheduled refresh can fail and retry later.")
            } header: { Text("Operation Lifetime") }
        }
        .navigationTitle("How Connections Work")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vpn.refreshStatus() }
    }

}

struct LocalConnectionModeView: View {
    @State private var vpn = LocalVPNService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                ForEach(LocalConnectionMode.allCases) { mode in
                    SwiftUI.Button {
                        Task {
                            do { try await vpn.selectMode(mode); dismiss() }
                            catch { errorMessage = error.localizedDescription }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: mode == .external ? "arrow.up.forward.app" : "network.badge.shield.half.filled")
                                .frame(width: 28).foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(mode.title).foregroundStyle(.primary)
                                Text(mode == .external ? "Works with free Apple Accounts. Connect in LocalDevVPN." : "Connects automatically. Requires the optional IPA and eligible signing profiles.")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if vpn.mode == mode { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                        .padding(.vertical, Spacing.xxs)
                    }
                    .disabled(vpn.isBusy || (mode == .builtIn && !vpn.hasSupportedProfiles))
                }
            } footer: {
                Text("The built-in option is available only when both SideKick and its extension are signed with Network Extension permission. LocalDevVPN remains available for every account type.")
            }
        }
        .navigationTitle("Connection Method")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Connection Method", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            SwiftUI.Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
}
