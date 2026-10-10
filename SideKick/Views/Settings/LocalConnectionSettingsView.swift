import SwiftUI

struct LocalConnectionSettingsView: View {
    @State private var vpn = LocalVPNService.shared
    @State private var isWorking = false
    @State private var message: String?
    @State private var showingMessage = false
    @State private var confirmingRemoval = false
    @State private var lastVerification: Date?

    var body: some View {
        Form {
            Section {
                Label { LabeledContent("Local Connection", value: vpn.statusLabel) } icon: {
                    Image(systemName: vpn.status == .connected ? "checkmark.shield.fill" : "network.badge.shield.half.filled")
                        .foregroundStyle(vpn.status == .connected ? .green : .blue)
                }
                .fullWidthListSeparators()
                LabeledContent("Connection Control", value: "Automatic")
                if vpn.isBusy { Label("An operation is using the connection", systemImage: "arrow.triangle.2.circlepath") }
                if !vpn.isConfigured {
                    SwiftUI.Button { Task { await authorize() } } label: {
                        Label("Allow Local Connection", systemImage: "checkmark.shield")
                    }.disabled(isWorking || vpn.isBusy)
                }
            } header: { Text("SideKick VPN") } footer: {
                Text("SideKick connects for installs, refreshes, pairing checks, and JIT. It disconnects after the last operation finishes. If SideKick stops responding, its VPN disconnects automatically within 90 seconds. No on-demand or always-on VPN is configured.")
            }
            Section {
                SwiftUI.Button { Task { await verify() } } label: {
                    HStack {
                        Label("Verify Device Connection", systemImage: "iphone.gen3.radiowaves.left.and.right")
                        Spacer()
                        if isWorking { ProgressView() }
                    }
                }.disabled(isWorking || vpn.isBusy || !vpn.isConfigured)
                if let lastVerification { LabeledContent("Last Verified", value: lastVerification.formatted(date: .abbreviated, time: .shortened)) }
            } header: { Text("Connection Check") } footer: {
                Text("This check briefly connects the VPN and verifies this iPhone using its pairing file. It disconnects automatically afterward. Another VPN may need to be disconnected before SideKick can use its local tunnel.")
            }
            Section {
                LabeledContent("Tunnel Extension", value: vpn.extensionBundleIdentifier == nil ? "Missing" : "Included")
                LabeledContent("Signing Capability", value: vpn.hasSupportedProfiles ? "Supported" : "Re-sign Required")
                LabeledContent("Local Interface", value: "10.7.1.1")
                LabeledContent("Local Peer", value: "10.7.0.1")
                LabeledContent("Internet Traffic", value: "Regular Connection")
                NavigationLink { LocalConnectionHelpView() } label: {
                    Label("Signing & VPN Permission", systemImage: "questionmark.circle")
                }.fullWidthListSeparators()
            } header: { Text("Details") }
            if vpn.isConfigured {
                Section {
                    SwiftUI.Button("Remove VPN Permission", role: .destructive) { confirmingRemoval = true }
                        .disabled(isWorking || vpn.isBusy)
                } footer: { Text("You will need to allow SideKick’s VPN again before installing or refreshing.") }
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
            message = "This iPhone is reachable. SideKick has finished the connection check and requested VPN disconnection."
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
                Label("Approve the iOS VPN alert", systemImage: "checkmark.shield")
                Text("Choose Allow Local Connection in SideKick. iOS asks to add a VPN configuration and may require your passcode. This permission is needed once per installation or after removing the configuration.")
            } header: { Text("VPN Permission") }
            Section {
                Label("Sign the app and extension", systemImage: "signature")
                Text("Keep SideKickVPN enabled when signing the IPA. Both SideKick and its extension need provisioning profiles containing the Network Extension packet-tunnel-provider capability. Free Apple ID provisioning does not support this capability. Use an eligible Apple Developer signing profile and preserve the extension’s entitlements.")
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
