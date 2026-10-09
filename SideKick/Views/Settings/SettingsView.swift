import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("About") {
                    LabeledContent("Version", value: "1.0.0")
                    Link(destination: URL(string: "https://github.com/huzaifah1530-bot/SideKick")!) {
                        Label("SideKick on GitHub", systemImage: "arrow.up.right")
                    }
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
