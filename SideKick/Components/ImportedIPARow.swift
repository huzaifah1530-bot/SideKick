import SwiftUI

struct ImportedIPARow: View {
    let app: ImportedIPA

    var body: some View {
        SideKickLibraryAppRow(
            name: app.name,
            versionText: "Version \(app.version)",
            iconData: app.iconData,
            metadata: { Text("Ready to install").font(.subheadline).foregroundStyle(.secondary) },
            status: { EmptyView() }
        )
    }
}
