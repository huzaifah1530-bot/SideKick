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
        HStack(spacing: 12) {
            Group {
                if let iconData, let icon = UIImage(data: iconData) {
                    Image(uiImage: icon).resizable().scaledToFit()
                } else {
                    Image(systemName: "app.fill")
                        .resizable().scaledToFit().padding(12)
                        .foregroundStyle(.white)
                        .background(Color.sideKickAccent.gradient)
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(.rect(cornerRadius: 12))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.body.weight(.semibold))
                Text(versionText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                metadata
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            status
        }
        .padding(.vertical, 4)
    }
}
