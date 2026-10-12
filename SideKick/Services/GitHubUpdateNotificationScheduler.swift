import Foundation
import UserNotifications

struct GitHubUpdateNotificationRoute: Codable, Hashable, Sendable {
    let bundleIdentifier: String
    let updateKey: String
    let targetKind: GitHubUpdateTarget.Kind
    let sourceIdentity: String?
}

enum GitHubUpdateNotificationRouteStore {
    static let tappedNotification = Notification.Name("sideKickGitHubUpdateNotificationTapped")
    private static let pendingRouteKey = "sidekick.github-update.pending-route"

    static func recordTap(userInfo: [AnyHashable: Any]) {
        guard let bundleIdentifier = userInfo["bundleIdentifier"] as? String,
              !bundleIdentifier.isEmpty, bundleIdentifier.count <= 512,
              let updateKey = userInfo["updateKey"] as? String,
              !updateKey.isEmpty, updateKey.count <= 1_024,
              let targetKindValue = userInfo["targetKind"] as? String,
              let targetKind = GitHubUpdateTarget.Kind(rawValue: targetKindValue) else { return }
        let sourceIdentity = userInfo["sourceIdentity"] as? String
        if let sourceIdentity, sourceIdentity.isEmpty || sourceIdentity.count > 1_024 { return }

        let route = GitHubUpdateNotificationRoute(
            bundleIdentifier: bundleIdentifier,
            updateKey: updateKey,
            targetKind: targetKind,
            sourceIdentity: sourceIdentity
        )
        guard let data = try? JSONEncoder().encode(route) else { return }
        UserDefaults.standard.set(data, forKey: pendingRouteKey)
        Task { @MainActor in
            NotificationCenter.default.post(name: tappedNotification, object: nil)
        }
    }

    static func pendingRoute() -> GitHubUpdateNotificationRoute? {
        guard let data = UserDefaults.standard.data(forKey: pendingRouteKey) else { return nil }
        return try? JSONDecoder().decode(GitHubUpdateNotificationRoute.self, from: data)
    }

    static func clearPendingRoute(_ route: GitHubUpdateNotificationRoute) {
        guard pendingRoute() == route else { return }
        UserDefaults.standard.removeObject(forKey: pendingRouteKey)
    }
}

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
            var userInfo: [AnyHashable: Any] = [
                "bundleIdentifier": candidate.bundleIdentifier,
                "updateKey": candidate.updateKey,
                "targetKind": candidate.targetKind.rawValue
            ]
            if let sourceIdentity = candidate.sourceIdentity {
                userInfo["sourceIdentity"] = sourceIdentity
            }
            content.userInfo = userInfo
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
