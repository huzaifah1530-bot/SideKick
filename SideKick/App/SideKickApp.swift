import SwiftUI
import UIKit
import UserNotifications

// Dormant standalone bootstrap: the integrated product excludes this file.
// Its active root and scene lifecycle are installed by the SideStore integration patch.
@main
struct SideKickApp: App {
    @State private var environment = AppEnvironment()

    init() {
        UITableView.appearance().separatorInset = .zero
        UITableView.appearance().separatorInsetReference = .fromCellEdges
        UNUserNotificationCenter.current().delegate = SideKickNotificationPresentationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(environment)
                .tint(.sideKickAccent)
        }
    }
}
