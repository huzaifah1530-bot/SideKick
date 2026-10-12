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
    private(set) var hasLoadedLiveContainerCatalogue = false
    private(set) var isLoadingLiveContainerCatalogue = false
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
    @ObservationIgnored private var liveContainerLoadTask: Task<Void, Never>?
    @ObservationIgnored private var liveContainerReloadRequested = false
    @ObservationIgnored private var localReloadRequested = false
    @ObservationIgnored private var iconTask: Task<Void, Never>?
    @ObservationIgnored private var liveContainerScanTask: Task<Void, Never>?
    @ObservationIgnored private var githubScanTask: Task<Void, Never>?
    @ObservationIgnored private var githubGeneration = UUID()
    @ObservationIgnored private var githubTargetGenerations: [String: UUID] = [:]
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
                try SideKickDataDirectory.prepareBeforeDatabaseStart()
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
                    if let runningBundleID = Bundle(url: Bundle.Info.activeBundleURL)?.bundleIdentifier,
                       runningBundleID == Bundle.main.bundleIdentifier,
                       apps.contains(where: { $0.id == runningBundleID }) {
                        do {
                            _ = try await GitHubUpdateConfigurationStore.shared.ensureSelfUpdateConfiguration(
                                for: runningBundleID
                            )
                        } catch {
                            // Self-update configuration is ancillary to the
                            // installed-app catalogue and must not hide it.
                            debugLog("[SideKick] Could not prepare the self-update source: \(error.localizedDescription)")
                        }
                    }
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
        guard DatabaseManager.shared.isStarted else { return }
        liveContainerReloadRequested = true
        if let liveContainerLoadTask {
            await liveContainerLoadTask.value
            return
        }
        isLoadingLiveContainerCatalogue = true
        let task = Task { @MainActor in
            defer {
                isLoadingLiveContainerCatalogue = false
                liveContainerLoadTask = nil
            }
            repeat {
                liveContainerReloadRequested = false
                do {
                    liveContainerState = try await liveContainerStore.snapshot()
                    hasLoadedLiveContainerCatalogue = true
                    liveContainerLoadError = nil
                    debugLog("[SideKick] Published \(liveContainerState.apps.count) cached LiveContainer apps.")
                } catch {
                    liveContainerLoadError = error.localizedDescription
                }
            } while liveContainerReloadRequested
            if !isLoadingLocalApps { requestGitHubUpdateCheck() }
        }
        liveContainerLoadTask = task
        await task.value
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

    /// Reuses an in-flight app-owned discovery scan or starts one, then waits
    /// for its catalogue publications before a caller validates guest targets.
    func rescanLiveContainerAppsAndWait() async {
        rescanLiveContainerApps()
        guard let scan = liveContainerScanTask else { return }
        await scan.value
    }

    private var updateTargets: [GitHubUpdateTarget] {
        let pendingForgetGuestIDs = Set(liveContainerState.pendingForgetGuestIDs.values.flatMap { $0 })
        let eligible = Set(liveContainerState.connections.filter {
            $0.isConnected && $0.storageKind != .snapshot && $0.error == nil
        }.map(\.id))
        let guests = liveContainerState.apps.filter {
            eligible.contains($0.connectionID) && !pendingForgetGuestIDs.contains($0.id)
                && $0.isAvailable && $0.warning == nil
        }.map(\.updateTarget)
        var seen = Set<String>()
        return (installedApps.map(\.updateTarget) + guests).filter { seen.insert($0.id).inserted }
    }

    var hasGitHubUpdateTargets: Bool { !updateTargets.isEmpty }

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
        let targetGenerations = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, UUID()) })
        for (targetID, targetGeneration) in targetGenerations {
            githubTargetGenerations[targetID] = targetGeneration
        }
        isCheckingGitHubUpdates = true
        let targetIDs = Set(targets.map(\.id))
        githubUpdates.removeAll { !targetIDs.contains($0.bundleIdentifier) }
        githubChecks.removeAll { !targetIDs.contains($0.targetID) }
        githubScanTask = Task { @MainActor in
            let scanResult = await GitHubUpdateScanner.scanTargets(targets) { [weak self] check in
                guard let self else { return }
                guard let targetGeneration = targetGenerations[check.targetID] else { return }
                _ = await self.publishGitHubCheck(check, generation: generation,
                    targetGeneration: targetGeneration, targets: targets)
            }
            guard githubGeneration == generation else { return }
            isCheckingGitHubUpdates = false
            githubScanTask = nil
            if !Task.isCancelled, scanResult.checks.count < targets.count {
                githubCheckRequested = true
            }
            // Updated guest observations and explicit refresh requests get a
            // follow-up scan after this one has published its partial results.
            requestGitHubUpdateCheck()
        }
    }

    /// Wait for the app-owned update scan that a foreground refresh requested,
    /// including a coalesced follow-up queued while the current scan was active.
    /// Ordinary catalogue reloads do not call this, so startup stays local-first.
    func awaitPendingGitHubChecks() async {
        guard DatabaseManager.shared.isStarted, !githubChecksSuspended else { return }
        requestGitHubUpdateCheck()
        while !Task.isCancelled, !githubChecksSuspended {
            guard let scan = githubScanTask else { return }
            await scan.value
            // The owning scan requests any queued follow-up before it completes.
        }
    }

    /// Publishes a result obtained by a detail screen after validating its
    /// source and target against the current app-owned catalogue. A per-target
    /// generation prevents an older overlapping scan from replacing it.
    func publishDetailGitHubCheck(_ check: GitHubCheckResult, target: GitHubUpdateTarget) async -> Bool {
        guard check.targetID == target.id else { return false }
        let generation = githubGeneration
        // A failed read has no configuration to compare; publish it only as a
        // status, and let the shared publisher verify that storage is still unavailable.
        if check.state != .failed || check.checkedConfiguration != nil {
            do {
                guard try await GitHubUpdateConfigurationStore.shared.configuration(for: target.id)
                        == check.checkedConfiguration else { return false }
            } catch { return false }
        }
        guard githubGeneration == generation,
              let current = updateTargets.first(where: { $0.id == target.id }),
              signatures([target]) == signatures([current]) else { return false }
        if let candidate = check.candidate {
            guard candidate.bundleIdentifier == target.id,
                  candidate.targetKind == target.kind,
                  candidate.sourceIdentity == check.checkedConfiguration?.sourceIdentity else { return false }
        }
        let targetGeneration = UUID()
        githubTargetGenerations[target.id] = targetGeneration
        return await publishGitHubCheck(check, generation: generation,
            targetGeneration: targetGeneration, targets: [target])
    }

    @discardableResult
    private func publishGitHubCheck(
        _ check: GitHubCheckResult,
        generation: UUID,
        targetGeneration: UUID,
        targets: [GitHubUpdateTarget]
    ) async -> Bool {
        var configurationReadFailed = false
        do {
            let configuration = try await GitHubUpdateConfigurationStore.shared.configuration(for: check.targetID)
            guard configuration == check.checkedConfiguration else { return false }
        } catch {
            // A source-read failure is safe to publish as a failed status only;
            // it cannot authorize or replace an update candidate.
            guard check.state == .failed, check.checkedConfiguration == nil else { return false }
            configurationReadFailed = true
        }
        guard githubGeneration == generation,
              githubTargetGenerations[check.targetID] == targetGeneration,
              !Task.isCancelled,
              let checked = targets.first(where: { $0.id == check.targetID }),
              let current = updateTargets.first(where: { $0.id == check.targetID }),
              signatures([checked]) == signatures([current]) else { return false }
        githubChecks.removeAll { $0.targetID == check.targetID }
        githubChecks.append(check)
        if check.state != .failed && !configurationReadFailed {
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
                      githubTargetGenerations[check.targetID] == targetGeneration,
                      githubUpdates.contains(where: { $0.id == candidate.id }) else { return }
                await GitHubUpdateNotificationScheduler.notify([candidate])
            }
        }
        return true
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
