import SwiftUI
import UIKit

@main
struct SideKickApp: App {
    @State private var environment = AppEnvironment()

    init() {
        UITableView.appearance().separatorInset = .zero
        UITableView.appearance().separatorInsetReference = .fromCellEdges
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(environment)
                .tint(.sideKickAccent)
        }
    }
}
