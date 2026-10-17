import AppIntents
import Foundation

struct RefreshManagedAppsIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh SideKick Apps"
    static let description = IntentDescription(
        "Checks GitHub updates and quietly attempts to refresh every app managed by SideKick. If today's attempt does not finish successfully, the evening automation can retry."
    )
    static let openAppWhenRun = false

    /// Never throws. A thrown error stops the whole shortcut, so the automation's next step
    /// ("turn off VPN") would never run and the VPN would stay on. Failures are reported
    /// through a notification and the returned text instead.
    func perform() async throws -> some ReturnsValue<String> {
        let result = await DailyRefreshAutomation.run()
        let status = "outcome=\(result.outcome.rawValue); succeeded=\(result.succeeded); attempted=\(result.attempted)"
        return .result(value: status)
    }
}

struct RefreshAutomationFailure: LocalizedError {
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
            let service = SideStoreOperationService(accountStore: store, ipaStore: IPAImportStore.shared)
            let outcome = await service.refreshAllManagedAppsQuietly()
            guard outcome.succeeded == outcome.attempted, outcome.attempted > 0 else {
                let result = shortcutOutcome(for: outcome.failure)
                if result != .noEligibleApps {
                    let items = outcome.appResults.filter { !$0.succeeded }.map {
                        RefreshFailureReport.Item(appName: $0.appName, message: $0.failureMessage ?? "Refresh failed.")
                    }
                    await reportFailure(
                        summary: RefreshAutomationFailure(outcome: result, succeeded: outcome.succeeded, attempted: outcome.attempted)
                            .errorDescription ?? "The refresh didn’t finish.",
                        detail: outcome.failureMessage,
                        items: items,
                        service: service
                    )
                }
                return (result, outcome.succeeded, outcome.attempted)
            }
            UserDefaults.standard.set(Date.now, forKey: lastSuccessfulRunKey)
            RefreshFailureReport.clear()
            return (.success, outcome.succeeded, outcome.attempted)
        } catch {
            debugLog("[SideKick] Scheduled refresh did not complete: \(error.localizedDescription)")
            let result: RefreshShortcutOutcome = error is LocalVPNError ? .connectionUnavailable : .operationUnavailable
            await reportFailure(
                summary: RefreshAutomationFailure(outcome: result, succeeded: 0, attempted: 0).errorDescription ?? "The refresh didn’t start.",
                detail: error.localizedDescription,
                items: [],
                service: SideStoreOperationService(accountStore: SigningAccountStore(), ipaStore: IPAImportStore.shared)
            )
            return (result, 0, 0)
        }
    }

    /// Saves what went wrong and notifies only when the soonest-expiring app has 4 days or fewer.
    private static func reportFailure(summary: String, detail: String?, items: [RefreshFailureReport.Item],
                                      service: SideStoreOperationService) async {
        let apps = await service.installedApps().filter(\.isActive)
        let soonest = apps.min { $0.expirationDate < $1.expirationDate }
        let days = soonest.map { $0.expirationDate <= .now ? 0 : SigningExpiry.daysRemaining(until: $0.expirationDate) } ?? 7
        var allItems = items
        if allItems.isEmpty, let detail, !detail.isEmpty {
            allItems = [RefreshFailureReport.Item(appName: "Refresh", message: detail)]
        }
        let report = RefreshFailureReport(date: .now, summary: summary, items: allItems,
                                          soonestDays: days, soonestAppName: soonest?.name)
        report.save()
        await report.notifyIfNeeded()
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
