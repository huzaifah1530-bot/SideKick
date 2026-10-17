import SwiftUI

struct ImportedIPARow: View {
    let app: ImportedIPA

    var body: some View {
        SideKickLibraryAppRow(
            name: app.name,
            versionText: app.version,
            iconData: app.iconData,
            metadata: { EmptyView() },
            status: { EmptyView() }
        )
    }
}
