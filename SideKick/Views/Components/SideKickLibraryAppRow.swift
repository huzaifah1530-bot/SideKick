import SwiftUI
import UIKit

struct SideKickLibraryAppRow<Metadata: View, Status: View>: View {
    let name: String
    let versionText: String
    let iconData: Data?
    let metadata: Metadata
    let status: Status

    init(
        name: String,
        versionText: String,
        iconData: Data?,
        @ViewBuilder metadata: () -> Metadata,
        @ViewBuilder status: () -> Status
    ) {
        self.name = name
        self.versionText = versionText
        self.iconData = iconData
        self.metadata = metadata()
        self.status = status()
    }

    var body: some View {
        HStack(spacing: Spacing.s) {
            SideKickAppIcon(data: iconData, size: .list)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(versionText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                metadata
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            status
        }
        .padding(.vertical, Spacing.xxs)
    }
}
