import SwiftUI

struct StatusPill: View {
    let app: SideloadedApp

    var body: some View {
        Label(app.expiryLabel, systemImage: app.status == .needsAttention ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(app.status == .needsAttention ? .orange : .green)
    }
}
