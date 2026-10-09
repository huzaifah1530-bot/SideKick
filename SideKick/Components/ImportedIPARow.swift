import SwiftUI

struct ImportedIPARow: View {
    let app: ImportedIPA

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "app.dashed")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(.blue.gradient, in: .rect(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 5) {
                Text(app.name).font(.headline)
                Text("Version \(app.version)").font(.caption).foregroundStyle(.secondary)
                Text(app.bundleIdentifier).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                .accessibilityLabel("Imported")
        }
        .padding(14)
        .background(.background, in: .rect(cornerRadius: 20))
    }
}
