import SwiftUI

// MARK: - Colour

@MainActor
extension Color {
    /// The accent: SideKick Teal by default (light `#007A74`, dark `#3DD6C6`), or the colour
    /// chosen in Settings → Appearance. Reading it inside a view body subscribes to changes.
    static var sideKickAccent: Color { AppearanceSettings.shared.accent }
    /// Label colour for content placed on a solid `sideKickAccent` fill.
    static var sideKickOnAccent: Color { AppearanceSettings.shared.onAccent }
    /// Low-contrast accent surface for selected or highlighted content.
    static var sideKickAccentTint: Color { AppearanceSettings.shared.accentTint }

    /// Kept for the SideStore host patch, which tints the root with `.sideKickBlue`.
    static var sideKickBlue: Color { sideKickAccent }
    static var sideKickCanvas: Color { Color(uiColor: .systemGroupedBackground) }
}

@MainActor
extension UIColor {
    static var sideKickAccent: UIColor { AppearanceSettings.shared.accentUIColor }
}

// MARK: - Spacing

/// The only spacing values SideKick's custom layouts use. Adjacent steps differ by at least 25%
/// from 12 upward, so the choice between neighbours is always obvious.
enum Spacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48
    static let xxxl: CGFloat = 64
}

/// Comfortable reading width for explanatory and error text on wide screens.
enum SideKickLayout {
    static let readableWidth: CGFloat = 560
}

// MARK: - Semantic status

enum StatusTone {
    case neutral, accent, success, warning, critical

    var color: Color {
        switch self {
        case .neutral: .secondary
        case .accent: .sideKickAccent
        case .success: .green
        case .warning: .orange
        case .critical: .red
        }
    }
}
