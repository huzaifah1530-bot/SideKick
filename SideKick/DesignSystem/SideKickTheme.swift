import SwiftUI

extension Color {
    static let sideKickBlue = Color(red: 0.12, green: 0.39, blue: 0.98)
    static let sideKickInk = Color.primary
    static let sideKickCanvas = Color(uiColor: .systemGroupedBackground)
}

extension View {
    @ViewBuilder
    func sideKickGlass() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: 24))
        } else {
            self.background(.regularMaterial, in: .rect(cornerRadius: 24))
        }
    }
}
