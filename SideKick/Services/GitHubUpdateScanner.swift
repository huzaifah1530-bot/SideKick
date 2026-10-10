import Foundation

enum GitHubUpdateScanner {
    struct Result: Sendable {
        var candidates: [GitHubUpdateCandidate] = []
        var didFail = false
    }

    static func scan(_ apps: [InstalledAppSummary]) async -> Result {
        var result = Result()
        let configurations = GitHubUpdateConfigurationStore()
        let service = GitHubUpdateService()
        for app in apps {
            guard !Task.isCancelled else { break }
            do {
                guard let configuration = try await configurations.configuration(for: app.bundleIdentifier) else { continue }
                let token = try GitHubCredentialStore().load(id: configuration.tokenID)
                if let candidate = try await service.candidate(for: app, configuration: configuration, token: token) {
                    result.candidates.append(candidate)
                }
            } catch {
                result.didFail = true
                debugLog("[SideKick] GitHub check failed for \(app.name): \(error.localizedDescription)")
            }
        }
        return result
    }

    @MainActor
    static func scanAndNotify() async {
        guard DatabaseManager.shared.isStarted else { return }
        let accounts = SigningAccountStore()
        let apps = await SideStoreOperationService(accountStore: accounts, ipaStore: IPAImportStore()).installedApps()
        // Keep background scans bounded so a slow repository cannot consume
        // the entire shortcut/background-refresh execution window.
        let result = await withTaskGroup(of: Result?.self) { group in
            group.addTask { await scan(apps) }
            group.addTask {
                try? await Task.sleep(for: .seconds(20))
                return nil
            }
            let first = await group.next()
            group.cancelAll()
            if let result = first ?? nil { return result }
            if let partial = await group.next() ?? nil { return partial }
            return Result(didFail: true)
        }
        guard !Task.isCancelled else { return }
        await GitHubUpdateNotificationScheduler.notify(result.candidates)
        UserDefaults.standard.set(Date.now, forKey: "sidekick.github.last-background-check")
    }
}
