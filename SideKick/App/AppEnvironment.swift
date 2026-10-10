import Foundation
import Observation

enum DatabaseStartupState: Equatable {
    case starting
    case ready
    case failed(String)
}

@MainActor
@Observable
final class AppEnvironment {
    let ipaImportStore: IPAImportStore
    let githubUpdateDownloads = GitHubUpdateDownloadStore()
    let liveContainerStore = LiveContainerStore.shared
    private(set) var databaseState: DatabaseStartupState = .starting
    private(set) var installedApps: [InstalledAppSummary] = []
    private(set) var liveContainerState = LiveContainerState()
    private(set) var liveContainerLoadError: String?
    private(set) var hasLoadedLocalApps = false
    private(set) var isLoadingLocalApps = false
    private(set) var localLoadError: String?
    private(set) var githubChecks: [GitHubCheckResult] = []
    private(set) var githubUpdates: [GitHubUpdateCandidate] = []
    private(set) var isCheckingGitHubUpdates = false
    var githubUpdateCheckFailed: Bool { githubChecks.contains { $0.state == .failed } }
    @ObservationIgnored private var databaseStartupTask: Task<Void, Never>?
    @ObservationIgnored private var maintenanceTask: Task<Void, Never>?
    @ObservationIgnored private var localLoadTask: Task<Void, Never>?
    @ObservationIgnored private var localReloadRequested = false
    @ObservationIgnored private var iconTask: Task<Void, Never>?
    @ObservationIgnored private var liveContainerScanTask: Task<Void, Never>?
    @ObservationIgnored private var githubScanTask: Task<Void, Never>?
    @ObservationIgnored private var githubGeneration = UUID()
    @ObservationIgnored private var lastCheckedTargets: [String] = []
    @ObservationIgnored private var githubCheckRequested = false
    @ObservationIgnored private var githubChecksSuspended = false

    init(ipaImportStore: IPAImportStore = IPAImportStore.shared) {
        self.ipaImportStore = ipaImportStore
    }

    func startDatabase() async {
        if case .ready = databaseState { return }
        if let databaseStartupTask {
            await databaseStartupTask.value
            return
        }
        let task = Task { @MainActor in
            databaseState = .starting
            do {
                try await DatabaseManager.shared.start()
                // Populate app-owned catalogues before Home is constructed. A
                // conditional List section is never responsible for bootstrapping.
                await reloadLocalCatalogues()
                databaseState = .ready
                scheduleMaintenance()
                rescanLiveContainerApps()
            } catch {
                databaseState = .failed(Self.readableDescription(for: error))
            }
        }
        databaseStartupTask = task
        await task.value
        databaseStartupTask = nil
    }

    func reloadLocalCatalogues(checkForUpdates: Bool = false) async {
        guard DatabaseManager.shared.isStarted else { return }
        localReloadRequested = true
        if checkForUpdates { githubCheckRequested = true }
        if let localLoadTask { await localLoadTask.value; return }
        let task = Task { @MainActor in
            isLoadingLocalApps = true
            repeat {
                localReloadRequested = false
                do {
                    let apps = try await SideStoreOperationService(accountStore: SigningAccountStore(),
                        ipaStore: ipaImportStore).loadInstalledApps(loadIcons: false)
                    let oldIcons = Dictionary(installedApps.map { ($0.id, $0.iconData) }, uniquingKeysWith: { first, _ in first })
                    installedApps = apps.map { value in
                        var app = value
                        app.iconData = oldIcons[app.id] ?? nil
                        return app
                    }
                    hasLoadedLocalApps = true
                    localLoadError = nil
                    debugLog("[SideKick] Published \(apps.count) installed app records before network checks.")
                } catch {
                    localLoadError = error.localizedDescription
                    debugLog("[SideKick] Local catalogue read failed: \(error.localizedDescription)")
                }
                await reloadLiveContainerCatalogue()
            } while localReloadRequested
            isLoadingLocalApps = false
            localLoadTask = nil
            requestGitHubUpdateCheck()
            loadAppIcons()
        }
        localLoadTask = task
        // The app owns this task; cancellation of a view's .task cannot throw
        // away the first local result or reset the catalogue to an empty array.
        await task.value
    }

    func reloadLiveContainerCatalogue() async {
        do {
            liveContainerState = try await liveContainerStore.snapshot()
            liveContainerLoadError = nil
            debugLog("[SideKick] Published \(liveContainerState.apps.count) cached LiveContainer apps.")
        } catch {
            liveContainerLoadError = error.localizedDescription
        }
        if !isLoadingLocalApps { requestGitHubUpdateCheck() }
    }

    func rescanLiveContainerApps() {
        guard DatabaseManager.shared.isStarted, liveContainerScanTask == nil else { return }
        liveContainerScanTask = Task { @MainActor in
            defer { liveContainerScanTask = nil }
            await reloadLiveContainerCatalogue()
            for connection in liveContainerState.connections where connection.isConnected && connection.storageKind != .snapshot {
                do { try await liveContainerStore.rescan(connection.id) }
                catch LiveContainerError.busy { }
                catch { debugLog("[SideKick] LiveContainer discovery failed: \(error.localizedDescription)") }
                // Publish each local directory independently of GitHub progress.
                await reloadLiveContainerCatalogue()
            }
        }
    }

    private var updateTargets: [GitHubUpdateTarget] {
        let eligible = Set(liveContainerState.connections.filter {
            $0.isConnected && $0.storageKind != .snapshot && $0.error == nil
        }.map(\.id))
        let guests = liveContainerState.apps.filter {
            eligible.contains($0.connectionID) && $0.isAvailable && $0.warning == nil
        }.map(\.updateTarget)
        var seen = Set<String>()
        return (installedApps.map(\.updateTarget) + guests).filter { seen.insert($0.id).inserted }
    }

    private func signatures(_ targets: [GitHubUpdateTarget]) -> [String] {
        targets.map { [$0.id, $0.version, $0.kind.rawValue, $0.observation ?? ""].joined(separator: "\n") }.sorted()
    }

    func requestGitHubUpdateCheck(force: Bool = false) {
        if force { githubCheckRequested = true }
        guard DatabaseManager.shared.isStarted, !isLoadingLocalApps, !githubChecksSuspended else { return }
        let targets = updateTargets
        let signature = signatures(targets)
        guard githubCheckRequested || lastCheckedTargets != signature else { return }
        // Ordinary local reloads queue new work; they never cancel a slow check.
        guard githubScanTask == nil else { return }
        githubCheckRequested = false
        lastCheckedTargets = signature
        let generation = UUID()
        githubGeneration = generation
        isCheckingGitHubUpdates = true
        let targetIDs = Set(targets.map(\.id))
        githubUpdates.removeAll { !targetIDs.contains($0.bundleIdentifier) }
        githubChecks.removeAll { !targetIDs.contains($0.targetID) }
        githubScanTask = Task { @MainActor in
            _ = await GitHubUpdateScanner.scanTargets(targets) { [weak self] check in
                guard let self else { return }
                await self.publishGitHubCheck(check, generation: generation, targets: targets)
            }
            guard githubGeneration == generation else { return }
            isCheckingGitHubUpdates = false
            githubScanTask = nil
            // Updated guest observations and explicit refresh requests get a
            // follow-up scan after this one has published its partial results.
            requestGitHubUpdateCheck()
        }
    }

    private func publishGitHubCheck(_ check: GitHubCheckResult, generation: UUID, targets: [GitHubUpdateTarget]) async {
        do {
            let configuration = try await GitHubUpdateConfigurationStore.shared.configuration(for: check.targetID)
            guard configuration == check.checkedConfiguration else { return }
        } catch {
            // A storage read error can be shown, but cannot authorize an update.
            guard check.state == .failed else { return }
        }
        guard githubGeneration == generation, !Task.isCancelled,
              let checked = targets.first(where: { $0.id == check.targetID }),
              let current = updateTargets.first(where: { $0.id == check.targetID }),
              signatures([checked]) == signatures([current]) else { return }
        githubChecks.removeAll { $0.targetID == check.targetID }
        githubChecks.append(check)
        if check.state != .failed {
            githubUpdates.removeAll { $0.bundleIdentifier == check.targetID }
            if let candidate = check.candidate { githubUpdates.append(candidate) }
        }
        githubUpdates.sort { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
        debugLog("[SideKick] Published GitHub result for \(check.targetID): \(check.state.rawValue).")
        // Rows are visible before queue restoration or notification requests.
        if let candidate = check.candidate {
            Task { @MainActor in
                await githubUpdateDownloads.restoreQueuedFiles(for: [candidate], ipaImportStore: ipaImportStore)
                guard githubGeneration == generation,
                      githubUpdates.contains(where: { $0.id == candidate.id }) else { return }
                await GitHubUpdateNotificationScheduler.notify([candidate])
            }
        }
    }

    func gitHubSettingsChanged() async {
        // Immediately remove stale source/skip/install results while rechecking.
        if let configurations = try? await GitHubUpdateConfigurationStore.shared.all() {
            githubUpdates.removeAll { candidate in
                guard let configuration = configurations.first(where: { $0.id == candidate.bundleIdentifier }) else { return true }
                let target = updateTargets.first { $0.id == candidate.bundleIdentifier }
                let receipt = configuration.installedBuild
                let confirmedInstalled = target?.observation != nil
                    && receipt?.observation == target?.observation
                    && receipt?.sourceIdentity == configuration.sourceIdentity
                    && receipt?.key == candidate.updateKey
                return configuration.sourceIdentity != candidate.sourceIdentity
                    || configuration.dismissedUpdateKey == candidate.updateKey
                    || confirmedInstalled
            }
        }
        requestGitHubUpdateCheck(force: true)
    }

    func pauseGitHubChecks() {
        githubChecksSuspended = true
        githubGeneration = UUID()
        githubScanTask?.cancel()
        githubScanTask = nil
        isCheckingGitHubUpdates = false
        githubCheckRequested = true
    }

    func resumeGitHubChecks() {
        githubChecksSuspended = false
    }

    private func loadAppIcons() {
        guard iconTask == nil, hasLoadedLocalApps else { return }
        let initial = signatures(installedApps.map(\.updateTarget))
        iconTask = Task { @MainActor in
            defer {
                iconTask = nil
                if signatures(installedApps.map(\.updateTarget)) != initial { loadAppIcons() }
            }
            guard let apps = try? await SideStoreOperationService(accountStore: SigningAccountStore(),
                ipaStore: ipaImportStore).loadInstalledApps() else { return }
            installedApps = installedApps.map { value in
                var app = value
                if let loaded = apps.first(where: { $0.id == app.id }),
                   signatures([loaded.updateTarget]) == signatures([app.updateTarget]) {
                    app.iconData = loaded.iconData
                }
                return app
            }
        }
    }

    // Start only after the local catalogue has been published. Maintenance must
    // never hold the launch screen or the app list behind filesystem work.
    func scheduleMaintenance() {
        guard case .ready = databaseState, maintenanceTask == nil else { return }
        maintenanceTask = Task { @MainActor in
            defer { maintenanceTask = nil }
            guard !Task.isCancelled else { return }
            do { try await ipaImportStore.cleanupOrphanedManagedIPAs() }
            catch { debugLog("[SideKick] Could not clean unused downloaded IPAs: \(error.localizedDescription)") }
            guard !Task.isCancelled else { return }
            await SideStoreOperationService.pruneUnusedCaches()
            guard !Task.isCancelled else { return }
            await ExpirationNotificationScheduler.update()
        }
    }

    private static func readableDescription(for error: Error) -> String {
        let nsError = error as NSError
        var details = [nsError.localizedDescription]
        if let reason = nsError.localizedFailureReason, !reason.isEmpty {
            details.append(reason)
        }
        if let debug = nsError.userInfo[NSDebugDescriptionErrorKey] as? String, !debug.isEmpty {
            details.append(debug)
        }
        return Array(NSOrderedSet(array: details)).compactMap { $0 as? String }.joined(separator: "\n\n")
    }
}
