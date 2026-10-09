import SwiftUI
import UIKit
import UserNotifications

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
