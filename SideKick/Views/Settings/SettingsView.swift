import SwiftUI
import UIKit

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { RefreshSettingsView() } label: {
                        Label("App Refresh", systemImage: "arrow.clockwise")
                    }
                    NavigationLink { InstallSigningSettingsView() } label: {
                        Label("Install & Signing", systemImage: "signature")
                    }
                    NavigationLink { PermissionsSettingsView() } label: {
                        Label("Notifications", systemImage: "bell.badge")
                    }
                } header: {
                    Text("Signing")
                }

                Section {
                    NavigationLink { LocalConnectionSettingsView() } label: {
                        Label("Connection", systemImage: "network")
                    }
                    NavigationLink { LiveContainerConnectionsView() } label: {
                        Label("LiveContainer", systemImage: "square.stack.3d.up")
                    }
                } header: {
                    Text("Connections")
                }

                Section {
                    NavigationLink { AppearanceSettingsView() } label: {
                        Label("Appearance", systemImage: "paintpalette")
                    }
                    NavigationLink { AdvancedSettingsView() } label: {
                        Label("Advanced", systemImage: "wrench.and.screwdriver")
                    }
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown")
                    if let url = URL(string: "https://github.com/huzaifah1530-bot/SideKick") {
                        Link(destination: url) {
                            Label("SideKick on GitHub", systemImage: "safari")
                        }
                    }
                } header: {
                    Text("About")
                } footer: {
                    Text("SideKick uses open-source signing components. Their licenses are in the project source.")
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
                Text("SideKick reminds you before apps expire. iOS decides when background refresh runs.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Notifications")
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
            Section("Signing Services") {
                NavigationLink { ConnectionSettingsView() } label: {
                    Label("Pairing", systemImage: "iphone.gen3.radiowaves.left.and.right")
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
                    Label("GitHub Tokens", systemImage: "key")
                }
            }

            Section("Troubleshooting") {
                NavigationLink { HealthCheckView(readyTitle: "SideKick Ready") } label: {
                    Label("Health Check", systemImage: "stethoscope")
                }
                NavigationLink { DiagnosticsView() } label: {
                    Label("Diagnostics", systemImage: "list.bullet.clipboard")
                }
                NavigationLink { SettingsStorageView() } label: {
                    Label("Storage", systemImage: "internaldrive")
                }
            }

        }
        .listStyle(.insetGrouped)
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
    }
}
