import Foundation
import UserNotifications

/// What went wrong in the last automatic refresh, kept so the failure notification can open it.
struct RefreshFailureReport: Codable, Equatable, Sendable {
    struct Item: Codable, Equatable, Sendable {
        let appName: String
        let message: String
    }

    let date: Date
    let summary: String
    let items: [Item]
    let soonestDays: Int
    let soonestAppName: String?

    private static let key = "sidekick.automation.last-failure"
    private static let pendingKey = "sidekick.automation.failure-tapped"
    static let tappedNotification = Notification.Name("sideKickRefreshFailureNotificationTapped")
    static let notificationKind = "refreshFailure"

    static func load() -> RefreshFailureReport? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(RefreshFailureReport.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: pendingKey)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationID])
    }

    // MARK: Notification tap

    static func recordTapIfFailure(userInfo: [AnyHashable: Any]) -> Bool {
        guard userInfo["kind"] as? String == notificationKind else { return false }
        UserDefaults.standard.set(true, forKey: pendingKey)
        Task { @MainActor in NotificationCenter.default.post(name: tappedNotification, object: nil) }
        return true
    }

    /// Returns the report once per tap.
    static func consumePendingTap() -> RefreshFailureReport? {
        guard UserDefaults.standard.bool(forKey: pendingKey) else { return nil }
        UserDefaults.standard.set(false, forKey: pendingKey)
        return load()
    }

    // MARK: Posting

    private static let notificationID = "sidekick.refresh-failure"

    func notifyIfNeeded() async {
        guard await DailyRefreshReminderScheduler.isEnabled else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = "Automatic refresh didn’t finish"
        let left = soonestDays <= 0 ? "has expired" : "expires in \(soonestDays) \(soonestDays == 1 ? "day" : "days")"
        content.body = "\(soonestAppName ?? "An app") \(left). Tap to see what went wrong."
        content.sound = .default
        content.userInfo = ["kind": Self.notificationKind]
        // Replaces any earlier failure notice so only the latest one is shown.
        try? await center.add(UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: nil))
    }
}
