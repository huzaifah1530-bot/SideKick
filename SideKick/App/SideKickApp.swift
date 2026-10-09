import SwiftUI

@main
struct SideKickApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(environment)
                .tint(.sideKickBlue)
        }
    }
}
