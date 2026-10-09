import AppIntents
import Foundation
import Minimuxer

struct RefreshManagedAppsIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh SideKick Apps"
    static let description = IntentDescription(
        "Quietly attempts to refresh every app managed by SideKick. If today's attempt does not finish successfully, the evening automation can retry."
    )
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        await DailyRefreshAutomation.run()
        return .result()
    }
}

struct SideKickShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RefreshManagedAppsIntent(),
            phrases: ["Refresh eligible apps with \(.applicationName)"],
            shortTitle: "Refresh Apps",
            systemImageName: "arrow.clockwise"
        )
    }
}

@MainActor
private enum DailyRefreshAutomation {
    private static let lastSuccessfulRunKey = "sidekick.automation.last-successful-refresh"

    static func run() async {
        let calendar = Calendar.current
        if let lastSuccessfulRun = UserDefaults.standard.object(forKey: lastSuccessfulRunKey) as? Date,
           calendar.isDate(lastSuccessfulRun, inSameDayAs: .now) {
            return
        }

        UserDefaults.standard.set(Date.now, forKey: "sidekick.automation.last-attempt")
        do {
            if !DatabaseManager.shared.isStarted {
                try await DatabaseManager.shared.start()
            }
            guard let pairingFile = PairingFileManager.shared.fetchPairingFile() else { return }
            guard Minimuxer.shared.network.activeInterfaces.contains(where: { $0.name.lowercased().hasPrefix("utun") && $0.ip.hasPrefix("10.7.") }) else {
                return
            }

            try await AppBootManager.shared.startMinimuxer(pairingFile: pairingFile)
            try await ensureMinimuxerReady()

            let store = SigningAccountStore()
            await store.reload()
            let outcome = await SideStoreOperationService(accountStore: store, ipaStore: IPAImportStore())
                .refreshAllManagedAppsQuietly()
            guard outcome.attempted > 0, outcome.succeeded == outcome.attempted else { return }
            UserDefaults.standard.set(Date.now, forKey: lastSuccessfulRunKey)
        } catch {
            // The two daily Shortcuts automations are a silent retry window, not user-facing alerts.
            debugLog("[SideKick] Scheduled refresh did not complete: \(error.localizedDescription)")
        }
    }
}
