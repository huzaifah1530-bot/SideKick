import Foundation

extension Notification.Name {
    static let sideKickLiveContainerCheckRequested = Notification.Name("SideKick.LiveContainerCheckRequested")
}

enum GitHubUpdateScanner {
    struct Result: Sendable {
        var candidates: [GitHubUpdateCandidate] = []
        var didFail = false
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

    static func scanTargets(_ apps: [GitHubUpdateTarget]) async -> Result {
        var result = Result()
        let configurations = GitHubUpdateConfigurationStore.shared
        let service = GitHubUpdateService()
        for app in apps {
            guard !Task.isCancelled else { break }
            do {
                guard let configuration = try await configurations.configuration(for: app.id) else { continue }
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
        let apps = await SideStoreOperationService(accountStore: accounts, ipaStore: IPAImportStore.shared).installedApps()
        // Keep background scans bounded so a slow repository cannot consume
        // the entire shortcut/background-refresh execution window.
        let result = await withTaskGroup(of: Result?.self) { group in
            group.addTask {
                var result = await scan(apps)
                let guests = await scanGuests()
                result.candidates += guests.candidates
                result.didFail = result.didFail || guests.didFail
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
