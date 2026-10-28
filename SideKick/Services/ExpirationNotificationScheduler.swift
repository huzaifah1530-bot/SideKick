import Foundation
import CoreData
import UserNotifications

@MainActor
enum ExpirationNotificationScheduler {
    static func update() async {
        // Replace the old one-off expiry thresholds with the daily missed-refresh check.
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let oldIDs = pending.map(\.identifier).filter {
            $0.hasPrefix("sidekick.expiration.") || $0.hasPrefix("sidestore-expiration-warning.")
        }
        center.removePendingNotificationRequests(withIdentifiers: oldIDs)
        if DatabaseManager.shared.isStarted {
            let context = DatabaseManager.shared.viewContext
            if let records = try? await context.perform({
                try context.fetch(InstalledApp.fetchRequest()).filter(\.isActive).map { ($0.resignedBundleIdentifier, $0.refreshedDate) }
            }) {
                let active = records.filter { !AppOffloadService.blocksNativeOperations($0.0) }
                let last = UserDefaults.standard.object(forKey: DailyRefreshReminderScheduler.successKey) as? Date
                if !active.isEmpty, active.allSatisfy({ Calendar.current.isDateInToday($0.1) }),
                   last.map({ !Calendar.current.isDateInToday($0) }) ?? true {
                    await DailyRefreshReminderScheduler.recordSuccess()
                    return
                }
            }
        }
        await DailyRefreshReminderScheduler.update()
    }
}

@MainActor
enum DailyRefreshReminderScheduler {
    static let enabledKey = "sidekick.automation.reminders-enabled"
    static let hourKey = "sidekick.automation.refresh-hour"
    static let minuteKey = "sidekick.automation.refresh-minute"
    static let successKey = "sidekick.automation.last-successful-refresh"
    private static let prefix = "sidekick.daily-refresh."
    private static var generation = UUID()

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    static func recordSuccess() async {
        UserDefaults.standard.set(Date.now, forKey: successKey)
        RefreshFailureReport.clear()
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        center.removeDeliveredNotifications(withIdentifiers: delivered.map { $0.request.identifier }.filter { $0.hasPrefix(prefix) })
        await update()
    }

    static func update() async {
        let token = UUID()
        generation = token
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        guard generation == token else { return }
        let oldIDs = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: oldIDs)
        // Old immediate failure notifications also respect the new preference.
        center.removePendingNotificationRequests(withIdentifiers: ["sidekick.refresh-failure"])
        guard isEnabled else {
            let delivered = await center.deliveredNotifications()
            guard generation == token else { return }
            center.removeDeliveredNotifications(withIdentifiers: delivered.map { $0.request.identifier }.filter { $0.hasPrefix(prefix) } + ["sidekick.refresh-failure"])
            return
        }
        let settings = await center.notificationSettings()
        guard generation == token,
              settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let defaults = UserDefaults.standard
        let plan = DailyRefreshReminderPlan(
            hour: defaults.object(forKey: hourKey) as? Int ?? 9,
            minute: defaults.object(forKey: minuteKey) as? Int ?? 0)
        // Stay within iOS's notification budget, leaving space for other SideKick alerts.
        // Each open/shortcut run replenishes up to four weeks of missed-run reminders.
        let otherCount = pending.filter { !$0.identifier.hasPrefix(prefix) }.count
        let dates = plan.fireDates(now: .now, lastSuccess: defaults.object(forKey: successKey) as? Date,
                                   count: min(28, max(0, 60 - otherCount)))
        for (index, date) in dates.enumerated() {
            guard generation == token else { return }
            let content = UNMutableNotificationContent()
            content.title = "Daily refresh hasn't completed"
            content.body = "The scheduled time plus 10 minutes has passed without a successful refresh. Open SideKick to refresh your apps."
            content.sound = .default
            let identifier = prefix + token.uuidString + "." + String(index)
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            do {
                try await center.add(UNNotificationRequest(identifier: identifier, content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
                if generation != token { center.removePendingNotificationRequests(withIdentifiers: [identifier]); return }
            } catch {
                debugLog("[SideKick] Could not schedule daily refresh reminder: \(error.localizedDescription)")
            }
        }
    }
}
