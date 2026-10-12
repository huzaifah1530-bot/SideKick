import AppIntents
import Foundation

struct RefreshManagedAppsIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh SideKick Apps"
    static let description = IntentDescription(
        "Checks GitHub updates and quietly attempts to refresh every app managed by SideKick. If today's attempt does not finish successfully, the evening automation can retry."
    )
    static let openAppWhenRun = false

    func perform() async throws -> some ReturnsValue<String> {
        let result = await DailyRefreshAutomation.run()
        let status = "outcome=\(result.outcome.rawValue); succeeded=\(result.succeeded); attempted=\(result.attempted)"
        switch result.outcome {
        case .partialFailure, .operationUnavailable, .connectionUnavailable, .appListUnavailable:
            throw RefreshAutomationFailure(
                outcome: result.outcome,
                succeeded: result.succeeded,
                attempted: result.attempted
            )
        case .success, .alreadyRefreshed, .noEligibleApps:
            return .result(value: status)
        }
    }
}

private struct RefreshAutomationFailure: LocalizedError {
    let outcome: RefreshShortcutOutcome
    let succeeded: Int
    let attempted: Int

    var errorDescription: String? {
        switch outcome {
        case .partialFailure:
            return "SideKick refreshed \(succeeded) of \(attempted) apps. At least one app failed, so this shortcut run is marked as failed."
        case .operationUnavailable:
            return "SideKick could not start the refresh operation."
        case .connectionUnavailable:
            return "SideKick could not connect to the local signing service."
        case .appListUnavailable:
            return "SideKick could not load the app list."
        case .success, .alreadyRefreshed, .noEligibleApps:
            return nil
        }
    }
}

enum RefreshShortcutOutcome: String {
    case success
    case alreadyRefreshed
    case noEligibleApps
    case partialFailure
    case operationUnavailable
    case connectionUnavailable
    case appListUnavailable
}

@MainActor
private enum DailyRefreshAutomation {
    private static let lastSuccessfulRunKey = "sidekick.automation.last-successful-refresh"

    static func run() async -> (outcome: RefreshShortcutOutcome, succeeded: Int, attempted: Int) {
        UserDefaults.standard.set(Date.now, forKey: "sidekick.automation.last-attempt")
        do {
            try SideKickDataDirectory.prepareBeforeDatabaseStart()
            if !DatabaseManager.shared.isStarted {
                try await DatabaseManager.shared.start()
            }
            // GitHub needs internet access, not a local tunnel. Check on every
            // shortcut run, including retries and days already refreshed.
            await GitHubUpdateScanner.scanAndNotify()
            let calendar = Calendar.current
            if let lastSuccessfulRun = UserDefaults.standard.object(forKey: lastSuccessfulRunKey) as? Date,
               calendar.isDate(lastSuccessfulRun, inSameDayAs: .now) {
                return (.alreadyRefreshed, 0, 0)
            }
            let vpnLease = try await LocalVPNService.shared.acquire()
            defer { LocalVPNService.shared.release(vpnLease) }

            let store = SigningAccountStore()
            await store.reload()
            let outcome = await SideStoreOperationService(accountStore: store, ipaStore: IPAImportStore.shared)
                .refreshAllManagedAppsQuietly()
            guard outcome.succeeded == outcome.attempted, outcome.attempted > 0 else {
                return (shortcutOutcome(for: outcome.failure), outcome.succeeded, outcome.attempted)
            }
            UserDefaults.standard.set(Date.now, forKey: lastSuccessfulRunKey)
            return (.success, outcome.succeeded, outcome.attempted)
        } catch {
            // The two daily Shortcuts automations are a silent retry window, not user-facing alerts.
            debugLog("[SideKick] Scheduled refresh did not complete: \(error.localizedDescription)")
            return (error is LocalVPNError ? .connectionUnavailable : .operationUnavailable, 0, 0)
        }
    }

    private static func shortcutOutcome(for failure: QuietRefreshOutcome.Failure?) -> RefreshShortcutOutcome {
        switch failure {
        case .noEligibleApps: .noEligibleApps
        case .appListUnavailable: .appListUnavailable
        case .operationUnavailable: .operationUnavailable
        case .connectionUnavailable: .connectionUnavailable
        case .appRefreshFailed: .partialFailure
        case nil: .partialFailure
        }
    }
}
