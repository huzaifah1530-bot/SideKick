import Foundation

extension Notification.Name {
    static let sideKickLiveContainerCheckRequested = Notification.Name("SideKick.LiveContainerCheckRequested")
}

enum GitHubUpdateScanner {
    struct Result: Sendable {
        var candidates: [GitHubUpdateCandidate] = []
        var didFail = false
        var checks: [GitHubCheckResult] = []
    }

    static func scan(_ apps: [InstalledAppSummary]) async -> Result {
        await scanTargets(apps.map(\.updateTarget))
    }

    static func scanGuests() async -> Result {
        do {
            let before = try await LiveContainerStore.shared.snapshot()
            var scanFailed = false
            for connection in before.connections where connection.isConnected && connection.storageKind != .snapshot {
                do { try await LiveContainerStore.shared.rescan(connection.id) }
                catch LiveContainerError.busy { }
                catch { scanFailed = true }
            }
            let state = try await LiveContainerStore.shared.snapshot()
            let eligible = Set(state.connections.filter { $0.isConnected && $0.storageKind != .snapshot && $0.error == nil }.map(\.id))
            var result = await scanTargets(state.apps.filter { eligible.contains($0.connectionID) && $0.isAvailable && $0.warning == nil }.map(\.updateTarget))
            result.didFail = result.didFail || scanFailed
            return result
        } catch {
            debugLog("[SideKick] LiveContainer update catalogue failed: \(error.localizedDescription)")
            return Result(didFail: true)
        }
    }

    static func scanTargets(_ apps: [GitHubUpdateTarget],
        onCheck: @escaping @Sendable (GitHubCheckResult) async -> Void = { _ in }) async -> Result {
        var result = Result()
        // Each repository has its own service. Bound concurrency, but publish
        // completed checks immediately instead of waiting for a slow source.
        await withTaskGroup(of: GitHubCheckResult?.self) { group in
            var next = 0
            for _ in 0..<min(3, apps.count) {
                let app = apps[next]
                next += 1
                group.addTask { await checkTarget(app) }
            }
            while let completed = await group.next() {
                guard !Task.isCancelled else { group.cancelAll(); return }
                if let check = completed {
                    result.checks.append(check)
                    result.didFail = result.didFail || check.state == .failed
                    if let candidate = check.candidate { result.candidates.append(candidate) }
                    await onCheck(check)
                }
                if next < apps.count {
                    let app = apps[next]
                    next += 1
                    group.addTask { await checkTarget(app) }
                }
            }
        }
        return result
    }

    private static func checkTarget(_ app: GitHubUpdateTarget) async -> GitHubCheckResult? {
        var checkedConfiguration: GitHubUpdateConfiguration?
        do {
            try Task.checkCancellation()
            let configurations = GitHubUpdateConfigurationStore.shared
            guard let configuration = try await configurations.configuration(for: app.id) else {
                return GitHubCheckResult(targetID: app.id, state: .notConfigured)
            }
            checkedConfiguration = configuration
            let token = try GitHubCredentialStore().load(id: configuration.tokenID)
            var check = try await GitHubUpdateService().check(for: app, configuration: configuration, token: token)
            try Task.checkCancellation()
            // A skip, installation, or source edit during the request supersedes
            // its result. Never revive a dismissed or already installed update.
            guard try await configurations.configuration(for: app.id) == configuration else { return nil }
            check.checkedConfiguration = configuration
            return check
        } catch {
            guard !Task.isCancelled else { return nil }
            debugLog("[SideKick] GitHub check failed for \(app.name): \(error.localizedDescription)")
            return GitHubCheckResult(targetID: app.id, state: .failed, detail: error.localizedDescription,
                checkedConfiguration: checkedConfiguration)
        }
    }

    static func scanAll(_ apps: [InstalledAppSummary]) async -> Result {
        async let installedResult = scan(apps)
        async let guestResult = scanGuests()
        var result = await installedResult
        let guests = await guestResult
        result.candidates += guests.candidates
        result.checks += guests.checks
        result.didFail = result.didFail || guests.didFail
        return result
    }

    @MainActor
    static func scanAndNotify() async {
        guard DatabaseManager.shared.isStarted else { return }
        let accounts = SigningAccountStore()
        let apps = await SideStoreOperationService(accountStore: accounts, ipaStore: IPAImportStore.shared).installedApps()
        // Keep background scans bounded so a slow repository cannot consume
        // the entire shortcut/background-refresh execution window.
        let result = await withTaskGroup(of: Result?.self) { group in
            group.addTask {
                let result = await scanAll(apps)
                return result
            }
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
