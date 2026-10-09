import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Sideloading setup") {
                    LabeledContent("IPA import", value: "Available")
                    LabeledContent("Apple ID accounts", value: "Available")
                    LabeledContent("IPA signing and install", value: "Not connected")
                    LabeledContent("App refresh", value: "Not connected")
                }
                Section("About") {
                    LabeledContent("Version", value: "1.0.0")
                    Link(destination: URL(string: "https://github.com/SideStore/SideStore")!) {
                        Label("SideStore project", systemImage: "arrow.up.right.square")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.sideKickCanvas)
            .navigationTitle("Settings")
        }
    }
}
