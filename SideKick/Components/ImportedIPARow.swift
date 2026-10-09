import SwiftUI
import UIKit

struct ImportedIPARow: View {
    let app: ImportedIPA

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let data = app.iconData, let icon = UIImage(data: data) {
                    Image(uiImage: icon).resizable().scaledToFit()
                } else {
                    Image(systemName: "app.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.blue.gradient)
                }
            }
            .frame(width: 58, height: 58)
            .clipShape(.rect(cornerRadius: 13))

            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Version \(app.version)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 5)
    }
}
