import Foundation

struct SideloadedApp: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var bundleIdentifier: String
    var version: String
    var iconSystemName: String
    var accent: AppAccent
    var expiresAt: Date
    var status: AppStatus
    var signingAccountID: UUID?

    var daysRemaining: Int {
        max(0, Calendar.current.dateComponents([.day], from: .now, to: expiresAt).day ?? 0)
    }

    var expiryLabel: String {
        daysRemaining == 0 ? "Expires today" : "(daysRemaining) days left"
    }
}

enum AppStatus: String, Sendable {
    case active
    case refreshing
    case needsAttention
}

enum AppAccent: String, CaseIterable, Sendable {
    case blue, purple, orange, green, pink

    var colorName: String { rawValue }
}
