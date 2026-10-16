import SwiftUI
import UIKit

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Apps") {
                    NavigationLink { RefreshSettingsView() } label: {
                        Label("App Refresh", systemImage: "arrow.clockwise")
                    }
                    NavigationLink { InstallSigningSettingsView() } label: {
                        Label("Install & Signing", systemImage: "signature")
                    }
                    NavigationLink { LocalConnectionSettingsView() } label: {
                        Label("Local Connection", systemImage: "network")
                    }
                    NavigationLink { PermissionsSettingsView() } label: {
                        Label("Permissions", systemImage: "bell.badge")
                    }
                }

                Section("Integrations") {
                    NavigationLink { LiveContainerConnectionsView() } label: {
                        Label("LiveContainer", systemImage: "square.stack.3d.up")
                    }
                }

                Section {
                    NavigationLink { HealthCheckView(readyTitle: "SideKick Ready") } label: {
                        Label("Health Check", systemImage: "heart.text.square")
                    }
                    NavigationLink { AdvancedSettingsView() } label: {
                        Label("Advanced", systemImage: "gearshape.2")
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown")
                    Link(destination: URL(string: "https://github.com/huzaifah1530-bot/SideKick")!) {
                        Label("SideKick on GitHub", systemImage: "arrow.up.right")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
        }
    }
}

private struct PermissionsSettingsView: View {
    @State private var status = SetupStatus()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
            Section {
                LabeledContent("Notifications", value: status.notificationsEnabled ? "On" : "Off")
                if !status.notificationsEnabled {
                    SwiftUI.Button("Allow Notifications") { Task { await status.requestNotifications() } }
                        .disabled(status.isBusy)
                }
                LabeledContent("Background App Refresh", value: status.backgroundRefreshEnabled ? "On" : "Off")
                if status.backgroundRefreshRestricted {
                    Text("Background App Refresh is restricted on this iPhone.")
                        .foregroundStyle(.secondary)
                }
                Link("Open iOS Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
            } footer: {
                Text("Notifications can remind you before apps expire. iOS decides when background refresh runs.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Permissions")
        .navigationBarTitleDisplayMode(.inline)
        .task { await status.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await status.refresh() } }
        }
        .alert("Permissions", isPresented: Binding(
            get: { status.message != nil },
            set: { if !$0 { status.message = nil } }
        )) {
            SwiftUI.Button("OK", role: .cancel) { status.message = nil }
        } message: {
            Text(status.message ?? "")
        }
    }
}

private struct AdvancedSettingsView: View {
    var body: some View {
        List {
            Section("Connection") {
                NavigationLink { ConnectionSettingsView() } label: {
                    Label("Pairing & Ports", systemImage: "network.badge.shield.half.filled")
                }
                NavigationLink { AnisetteSettingsView() } label: {
                    Label("Anisette", systemImage: "lock.shield")
                }
            }

            Section("Updates") {
                NavigationLink { SkippedGitHubUpdatesView() } label: {
                    Label("Skipped Updates", systemImage: "arrow.uturn.backward")
                }
                NavigationLink { GitHubAccountSettingsView() } label: {
                    Label("GitHub Tokens", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                NavigationLink { GitHubDiagnosticsView() } label: {
                    Label("GitHub Update Logs", systemImage: "list.bullet.clipboard")
                }
            }

            Section("Troubleshooting") {
                NavigationLink { DiagnosticsView() } label: {
                    Label("Diagnostics", systemImage: "list.bullet.clipboard")
                }
                NavigationLink { SettingsStorageView() } label: {
                    Label("Storage", systemImage: "internaldrive")
                }
            }

            Section("Open Source") {
                Text("SideKick uses open-source signing components. Their notices and licenses are available in the project source.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
    }
}
