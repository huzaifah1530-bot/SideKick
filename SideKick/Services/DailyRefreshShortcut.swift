import AppIntents
import Foundation

struct RefreshManagedAppsIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh SideKick Apps"
    static let description = IntentDescription(
        "Checks GitHub updates and quietly attempts to refresh every app managed by SideKick. If today's attempt does not finish successfully, the evening automation can retry."
    )
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        await DailyRefreshAutomation.run()
        return .result()
    }
}

@MainActor
private enum DailyRefreshAutomation {
    private static let lastSuccessfulRunKey = "sidekick.automation.last-successful-refresh"

    static func run() async {
        UserDefaults.standard.set(Date.now, forKey: "sidekick.automation.last-attempt")
        do {
            if !DatabaseManager.shared.isStarted {
                try await DatabaseManager.shared.start()
            }
            // GitHub needs internet access, not a local tunnel. Check on every
            // shortcut run, including retries and days already refreshed.
            await GitHubUpdateScanner.scanAndNotify()
            let calendar = Calendar.current
            if let lastSuccessfulRun = UserDefaults.standard.object(forKey: lastSuccessfulRunKey) as? Date,
               calendar.isDate(lastSuccessfulRun, inSameDayAs: .now) { return }
            let vpnLease = try await LocalVPNService.shared.acquire()
            defer { LocalVPNService.shared.release(vpnLease) }

            let store = SigningAccountStore()
            await store.reload()
            let outcome = await SideStoreOperationService(accountStore: store, ipaStore: IPAImportStore.shared)
                .refreshAllManagedAppsQuietly()
            guard outcome.attempted > 0, outcome.succeeded == outcome.attempted else { return }
            UserDefaults.standard.set(Date.now, forKey: lastSuccessfulRunKey)
        } catch {
            // The two daily Shortcuts automations are a silent retry window, not user-facing alerts.
            debugLog("[SideKick] Scheduled refresh did not complete: \(error.localizedDescription)")
        }
    }
}
