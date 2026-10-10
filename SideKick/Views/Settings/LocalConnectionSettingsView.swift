import SwiftUI

struct LocalConnectionSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var vpn = LocalVPNService.shared
    @State private var isWorking = false
    @State private var message: String?
    @State private var showingMessage = false
    @State private var confirmingRemoval = false
    @State private var lastVerification: Date?

    var body: some View {
        Form {
            Section {
                NavigationLink { LocalConnectionModeView() } label: {
                    Label { LabeledContent("Connection Method", value: vpn.mode.title) } icon: { Image(systemName: "network") }
                }.fullWidthListSeparators()
                LabeledContent("Status", value: vpn.statusLabel)
                LabeledContent("Connection Control", value: vpn.mode == .builtIn ? "Automatic" : "LocalDevVPN")
                if vpn.isBusy { Label("An operation is using the connection", systemImage: "arrow.triangle.2.circlepath") }
            } header: { Text("Local Connection") }

            if vpn.mode == .external {
                Section {
                    SwiftUI.Button {
                        UIApplication.shared.open(vpn.externalInstalled ? LocalVPNService.externalURL : LocalVPNService.externalStoreURL)
                    } label: {
                        Label(vpn.externalInstalled ? "Connect LocalDevVPN" : "Get LocalDevVPN", systemImage: "arrow.up.forward.app")
                    }.disabled(isWorking || vpn.isBusy)
                } header: { Text("LocalDevVPN") } footer: {
                    Text("Connect LocalDevVPN, then return to SideKick. Free Apple Accounts use this separately signed VPN. SideKick cannot turn another app’s VPN off; disconnect it in LocalDevVPN when finished. Scheduled refreshes need its tunnel connected beforehand.")
                }
            } else if !vpn.isConfigured {
                Section {
                    SwiftUI.Button { Task { await authorize() } } label: {
                        HStack { Label("Allow Built-in VPN", systemImage: "checkmark.shield"); Spacer(); if isWorking { ProgressView() } }
                    }.disabled(isWorking || vpn.isBusy)
                } footer: {
                    Text("Approve the iOS VPN alert once. SideKick connects for device operations and disconnects when the last operation finishes.")
                }
            }
            Section {
                SwiftUI.Button { Task { await verify() } } label: {
                    HStack {
                        Label("Verify Device Connection", systemImage: "iphone.gen3.radiowaves.left.and.right")
                        Spacer()
                        if isWorking { ProgressView() }
                    }
                }.disabled(isWorking || vpn.isBusy || !vpn.isConnectionReady)
                if let lastVerification { LabeledContent("Last Verified", value: lastVerification.formatted(date: .abbreviated, time: .shortened)) }
            } header: { Text("Connection Check") } footer: {
                Text(vpn.mode == .builtIn
                    ? "Briefly connects SideKick’s VPN and checks this iPhone using its pairing file. The built-in tunnel disconnects afterward."
                    : "Checks this iPhone using its pairing file and the connected LocalDevVPN tunnel. This does not disconnect LocalDevVPN.")
            }
            Section {
                LabeledContent("Optional VPN Extension", value: vpn.extensionBundleIdentifier == nil ? "Not Included" : "Included")
                LabeledContent("Built-in VPN Signing", value: vpn.hasSupportedProfiles ? "Supported" : "Not Available")
                NavigationLink { LocalConnectionHelpView() } label: {
                    Label("Connection Help", systemImage: "questionmark.circle")
                }.fullWidthListSeparators()
            } header: { Text("Details") }
            if vpn.isConfigured {
                Section {
                    SwiftUI.Button("Remove Built-in VPN Permission", role: .destructive) { confirmingRemoval = true }
                        .disabled(isWorking || vpn.isBusy)
                } footer: { Text("Only SideKick’s own VPN configuration is removed. LocalDevVPN is kept.") }
            }
            Section {
                Link("LocalDevVPN Source & Credits", destination: URL(string: "https://github.com/seomin0610/LocalDevVPN")!)
                Text("SideKick’s tunnel uses code from LocalDevVPN by Stossy11, Magesh K, and the SideStore Team, with automatic connection management and a watchdog added by SideKick.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Local Connection")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vpn.refreshStatus() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await vpn.refreshStatus() } }
        }
        .refreshable { await vpn.refreshStatus() }
        .alert("Local Connection", isPresented: $showingMessage) {
            SwiftUI.Button("OK", role: .cancel) { }
        } message: { Text(message ?? "") }
        .alert("Remove VPN permission?", isPresented: $confirmingRemoval) {
            SwiftUI.Button("Remove Permission", role: .destructive) {
                Task {
                    do { try await vpn.removeConfiguration() }
                    catch { message = error.localizedDescription; showingMessage = true }
                }
            }
            SwiftUI.Button("Cancel", role: .cancel) { }
        } message: { Text("SideKick will ask for VPN permission again before its next device operation. Your apps and pairing file are kept.") }
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
            UserDefaults.standard.set(true, forKey: "sidekick.setup.pairing-verified")
            message = vpn.mode == .builtIn ? "This iPhone is reachable. The built-in VPN will disconnect after this check." : "This iPhone is reachable. LocalDevVPN remains connected."
        } catch { message = error.localizedDescription }
        showingMessage = true
    }
}

private enum PairingSetupErrorForVPN: LocalizedError {
    case missing
    var errorDescription: String? { "Import a pairing file for this iPhone in Settings → Connection & Pairing, then verify again." }
}

private struct LocalConnectionHelpView: View {
    var body: some View {
        List {
            Section {
                Label("Free Apple Accounts", systemImage: "person.crop.circle")
                Text("Use the standard SideKick IPA and LocalDevVPN from the App Store. Connect LocalDevVPN before installing, refreshing or enabling JIT. SideKick cannot control or disconnect another app’s tunnel.")
            } header: { Text("LocalDevVPN") }
            Section {
                Label("Approve the iOS VPN alert", systemImage: "checkmark.shield")
                Text("Choose Allow Local Connection in SideKick. iOS asks to add a VPN configuration and may require your passcode. This permission is needed once per installation or after removing the configuration.")
            } header: { Text("VPN Permission") }
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
        .navigationTitle("Connection Help")
        .navigationBarTitleDisplayMode(.inline)
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
                        .padding(.vertical, 6)
                    }
                    .disabled(vpn.isBusy || (mode == .builtIn && !vpn.hasSupportedProfiles))
                    .fullWidthListSeparators()
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
