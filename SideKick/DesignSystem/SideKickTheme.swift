import SwiftUI

// MARK: - Colour

extension Color {
    /// SideKick Teal. Light `#007A74` (5.2:1 on white), dark `#3DD6C6` (11.6:1 on black).
    static let sideKickAccent = Color("SideKickAccent")
    /// Label colour for content placed on a solid `sideKickAccent` fill.
    /// White in light mode; deep teal in dark mode, where white on the light teal fails contrast.
    static let sideKickOnAccent = Color("SideKickOnAccent")
    /// Low-contrast teal surface for selected or highlighted content.
    static let sideKickAccentTint = Color("SideKickAccentTint")

    /// Kept for the SideStore host patch, which tints the root with `.sideKickBlue`.
    static let sideKickBlue = sideKickAccent
    static let sideKickCanvas = Color(uiColor: .systemGroupedBackground)
}

extension UIColor {
    static let sideKickAccent = UIColor(named: "SideKickAccent") ?? .systemTeal
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
