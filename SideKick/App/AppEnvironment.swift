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
    @ObservationIgnored private var databaseStartupTask: Task<Void, Never>?
    @ObservationIgnored private var maintenanceTask: Task<Void, Never>?

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
                databaseState = .ready
            } catch {
                databaseState = .failed(Self.readableDescription(for: error))
            }
        }
        databaseStartupTask = task
        await task.value
        databaseStartupTask = nil
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
