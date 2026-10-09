import SwiftUI

struct AppIconView: View {
    let app: SideloadedApp
    var size: CGFloat = 58

    var body: some View {
        Image(systemName: app.iconSystemName)
            .font(.system(size: size * 0.43, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(appColor.gradient, in: .rect(cornerRadius: size * 0.22))
            .shadow(color: appColor.opacity(0.22), radius: 10, y: 4)
    }

    private var appColor: Color {
        switch app.accent { case .blue: .blue; case .purple: .purple; case .orange: .orange; case .green: .green; case .pink: .pink }
    }
}
