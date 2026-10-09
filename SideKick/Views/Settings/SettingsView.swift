import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Sideloading") {
                    Label("Refresh schedule", systemImage: "calendar.badge.clock")
                    Label("Pairing & device", systemImage: "iphone.gen3")
                }
                Section("About") {
                    LabeledContent("Version", value: "0.1.0")
                    Link(destination: URL(string: "https://github.com/SideStore/SideStore")!) { Label("SideStore project", systemImage: "arrow.up.right.square") }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.sideKickCanvas)
            .navigationTitle("Settings")
        }
    }
}
