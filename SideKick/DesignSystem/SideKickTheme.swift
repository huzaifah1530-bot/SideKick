import SwiftUI

extension Color {
    static let sideKickBlue = Color(red: 0.20, green: 0.43, blue: 1.00)
    static let sideKickViolet = Color(red: 0.43, green: 0.31, blue: 0.98)
    static let sideKickAccent = sideKickBlue
    static let sideKickInk = Color.primary
    static let sideKickCanvas = Color(uiColor: .systemGroupedBackground)

    static let sideKickAccentGradient = LinearGradient(
        colors: [.sideKickBlue, .sideKickViolet],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

extension View {
    @ViewBuilder
    func sideKickNavigationLinkIndicator() -> some View {
        if #available(iOS 26.0, *) {
            self.navigationLinkIndicatorVisibility(.hidden)
        } else {
            // Preserve the standard iOS 18 disclosure indicator.
            self
        }
    }

    @ViewBuilder
    func sideKickGlass() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: 24))
        } else {
            self.background(.regularMaterial, in: .rect(cornerRadius: 24))
        }
    }
}
