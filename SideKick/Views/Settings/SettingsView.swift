import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown")
                    Link(destination: URL(string: "https://github.com/huzaifah1530-bot/SideKick")!) {
                        Label("SideKick on GitHub", systemImage: "arrow.up.right")
                    }
                }

                Section("Install and refresh") {
                    NavigationLink {
                        RefreshSettingsView()
                    } label: {
                        Label("App Refresh", systemImage: "arrow.clockwise")
                    }
                    .fullWidthListSeparators()
                    NavigationLink {
                        InstallSigningSettingsView()
                    } label: {
                        Label("Install & Signing", systemImage: "signature")
                    }
                    .fullWidthListSeparators()
                    NavigationLink { LocalConnectionSettingsView() } label: {
                        Label("Local Connection", systemImage: "network.badge.shield.half.filled")
                    }
                    .fullWidthListSeparators()
                }

                Section("Device & Services") {
                    NavigationLink { LiveContainerConnectionsView() } label: {
                        Label("LiveContainer", systemImage: "square.stack.3d.up")
                    }
                    .fullWidthListSeparators()
                    NavigationLink {
                        ConnectionSettingsView()
                    } label: {
                        Label("Connection & Pairing", systemImage: "network")
                    }
                    .fullWidthListSeparators()
                    NavigationLink {
                        AnisetteSettingsView()
                    } label: {
                        Label("Anisette", systemImage: "lock.shield")
                    }
                    .fullWidthListSeparators()
                    NavigationLink {
                        SettingsStorageView()
                    } label: {
                        Label("Storage", systemImage: "internaldrive")
                    }
                    .fullWidthListSeparators()
                }

                Section("App updates") {
                    NavigationLink {
                        GitHubAccountSettingsView()
                    } label: {
                        Label("GitHub Tokens", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .fullWidthListSeparators()
                }

                Section {
                    Text("SideKick uses open-source signing components. Their notices and licenses are available in the project source.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Open Source")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
        }
    }
}
