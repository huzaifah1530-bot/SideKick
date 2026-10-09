import CoreData
import Foundation
import UserNotifications

@MainActor
enum ExpirationNotificationScheduler {
    private static let notificationPrefix = "sidekick.expiration."
    private static let twoDays: TimeInterval = 2 * 24 * 60 * 60

    static func update() async {
        let context = DatabaseManager.shared.viewContext
        let apps = await context.perform {
            var installedApps = (try? context.fetch(InstalledApp.fetchRequest())) ?? []
            if let sideKickApp = InstalledApp.fetchAltStore(in: context),
               !installedApps.contains(where: { $0.bundleIdentifier == sideKickApp.bundleIdentifier }) {
                installedApps.append(sideKickApp)
            }
            return installedApps.map { ($0.bundleIdentifier, $0.name, $0.expirationDate) }
        }

        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        let sideKickIDs = Set(apps.map { notificationPrefix + $0.0 })
        let legacyIDs = ["24h", "6h", "0h"].map { "sidestore-expiration-warning.\($0)" }
        let allIDs = pending.map(\.identifier) + delivered.map { $0.request.identifier }
        let obsoleteIDs = allIDs.filter {
            ($0.hasPrefix(notificationPrefix) && !sideKickIDs.contains($0)) || legacyIDs.contains($0)
        }
        if !obsoleteIDs.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: obsoleteIDs)
            center.removeDeliveredNotifications(withIdentifiers: obsoleteIDs)
        }

        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        for (bundleIdentifier, appName, expirationDate) in apps {
            let identifier = notificationPrefix + bundleIdentifier
            let deliveredForApp = delivered.first { $0.request.identifier == identifier }
            let deliveredExpiration = deliveredForApp?.request.content.userInfo["expirationTimestamp"] as? Double
            if let deliveredExpiration, abs(deliveredExpiration - expirationDate.timeIntervalSince1970) < 1 {
                center.removePendingNotificationRequests(withIdentifiers: [identifier])
                continue
            }
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
            guard expirationDate > .now else { continue }

            let secondsUntilWarning = expirationDate.timeIntervalSinceNow - twoDays
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, secondsUntilWarning), repeats: false)
            let content = UNMutableNotificationContent()
            content.title = "\(appName) expires in 2 days"
            content.body = "Open SideKick to refresh it before its signing expires."
            content.sound = .default
            content.userInfo = ["expirationTimestamp": expirationDate.timeIntervalSince1970]
            do {
                try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
            } catch {
                debugLog("[SideKick] Could not schedule expiry notification for \(bundleIdentifier): \(error.localizedDescription)")
            }
        }
    }
}
