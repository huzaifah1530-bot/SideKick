import Foundation
import UserNotifications

enum GitHubUpdateNotificationScheduler {
    private static let prefix = "sidekick.github-update."

    static func notify(_ candidates: [GitHubUpdateCandidate]) async {
        guard !candidates.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        for candidate in candidates where candidate.isKnownNewer {
            guard await isCurrentAndEligible(candidate) else { continue }
            let historyKey = prefix + candidate.bundleIdentifier + ".last-notified"
            if UserDefaults.standard.string(forKey: historyKey) == candidate.updateKey { continue }
            let appPrefix = prefix + candidate.bundleIdentifier + "."
            let updateID = Data(candidate.updateKey.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            let identifier = appPrefix + updateID
            if pending.contains(where: { $0.identifier == identifier })
                || delivered.contains(where: { $0.request.identifier == identifier }) {
                continue
            }

            let staleIDs = pending.map(\.identifier) + delivered.map { $0.request.identifier }
            let obsolete = staleIDs.filter { $0.hasPrefix(appPrefix) && $0 != identifier }
            if !obsolete.isEmpty, await isCurrentAndEligible(candidate) {
                center.removePendingNotificationRequests(withIdentifiers: obsolete)
                center.removeDeliveredNotifications(withIdentifiers: obsolete)
            }

            // The configuration may have changed while requests were being
            // inspected or obsolete reminders were removed. Preserve existing
            // reminders whenever eligibility cannot be confirmed.
            guard await isCurrentAndEligible(candidate) else { continue }

            let content = UNMutableNotificationContent()
            content.title = "\(candidate.appName) update available"
            content.body = candidate.targetKind == .liveContainer
                ? "\(candidate.newVersion) is available. Review this guest update in SideKick, then install it in LiveContainer."
                : "Version \(candidate.newVersion) is ready to install in SideKick."
            content.sound = .default
            content.userInfo = ["bundleIdentifier": candidate.bundleIdentifier, "updateKey": candidate.updateKey, "targetKind": candidate.targetKind.rawValue]
            do {
                try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
                // add() suspends. If the source was edited, skipped, or
                // installed during that suspension, discard only this request.
                guard await isCurrentAndEligible(candidate) else {
                    center.removePendingNotificationRequests(withIdentifiers: [identifier])
                    center.removeDeliveredNotifications(withIdentifiers: [identifier])
                    continue
                }
                UserDefaults.standard.set(candidate.updateKey, forKey: historyKey)
            } catch {
                debugLog("[SideKick] Could not post update notification for \(candidate.appName): \(error.localizedDescription)")
            }
        }
    }

    private static func isCurrentAndEligible(_ candidate: GitHubUpdateCandidate) async -> Bool {
        guard candidate.isKnownNewer, let expectedSource = candidate.sourceIdentity else { return false }
        do {
            guard let configuration = try await GitHubUpdateConfigurationStore.shared.configuration(
                for: candidate.bundleIdentifier
            ) else { return false }
            return configuration.sourceIdentity == expectedSource
                && configuration.dismissedUpdateKey != candidate.updateKey
                && configuration.effectiveBaselineKey != candidate.updateKey
                && configuration.installedBuild?.key != candidate.updateKey
        } catch {
            debugLog("[SideKick] Could not validate update notification for \(candidate.appName): \(error.localizedDescription)")
            return false
        }
    }
}

final class SideKickNotificationPresentationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = SideKickNotificationPresentationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
