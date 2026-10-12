import Foundation
import Observation

struct GitHubUpdateDownloadJob: Equatable {
    var progress: Double?
    var bytesWritten: Int64
    var totalBytesExpected: Int64?
    var isDownloading: Bool
    var queuedIPA: ImportedIPA?
    var errorMessage: String?
}

@MainActor
@Observable
final class GitHubUpdateDownloadStore {
    private(set) var jobs: [String: GitHubUpdateDownloadJob] = [:]
    @ObservationIgnored private var generations: [String: UUID] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var forgettingGuestTargets: Set<String> = []

    func start(
        candidate: GitHubUpdateCandidate,
        expectedBundleIdentifiers: Set<String>,
        ipaImportStore: IPAImportStore,
        token: String?
    ) {
        guard tasks[candidate.id] == nil,
              !forgettingGuestTargets.contains(candidate.bundleIdentifier),
              !SideKickStorageCleanup.isRemovingFiles else { return }
        let generation = UUID()
        let previousQueuedIPA = jobs[candidate.id]?.queuedIPA
        generations[candidate.id] = generation
        jobs[candidate.id] = GitHubUpdateDownloadJob(
            progress: nil,
            bytesWritten: 0,
            totalBytesExpected: nil,
            isDownloading: true,
            queuedIPA: previousQueuedIPA,
            errorMessage: nil
        )

        tasks[candidate.id] = Task { [weak self] in
            guard let self else { return }
            var temporaryURL: URL?
            defer {
                if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
            }
            do {
                let downloaded = try await GitHubUpdateService().downloadIPA(for: candidate, token: token) { progress in
                    Task { @MainActor in
                        if self.generations[candidate.id] == generation { self.setProgress(progress, for: candidate.id) }
                    }
                }
                temporaryURL = downloaded
                try Task.checkCancellation()
                let queuedIPA = try await ipaImportStore.importManagedIPA(
                    from: downloaded,
                    expectedBundleIdentifiers: expectedBundleIdentifiers,
                    updateKey: candidate.updateKey,
                    repositoryURL: candidate.repositoryURL,
                    targetID: candidate.bundleIdentifier,
                    sourceIdentity: candidate.sourceIdentity
                )
                guard self.generations[candidate.id] == generation else {
                    do { try await ipaImportStore.delete(queuedIPA) }
                    catch { debugLog("[SideKick] Could not remove a canceled GitHub update download: \(error.localizedDescription)") }
                    return
                }
                // Cancellation can arrive while importManagedIPA is suspended. Delete the
                // just-imported IPA and route through the normal cancellation cleanup so the
                // job becomes retryable instead of remaining stuck in its downloading state.
                if Task.isCancelled {
                    do { try await ipaImportStore.delete(queuedIPA) }
                    catch { debugLog("[SideKick] Could not remove a canceled GitHub update download: \(error.localizedDescription)") }
                    throw CancellationError()
                }
                self.jobs[candidate.id] = GitHubUpdateDownloadJob(
                    progress: 1,
                    bytesWritten: self.jobs[candidate.id]?.bytesWritten ?? 0,
                    totalBytesExpected: self.jobs[candidate.id]?.totalBytesExpected,
                    isDownloading: false,
                    queuedIPA: queuedIPA,
                    errorMessage: nil
                )
            } catch {
                guard self.generations[candidate.id] == generation else { return }
                let message: String
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    message = "Download canceled. Tap Try Again to restart."
                } else {
                    message = error.localizedDescription
                }
                self.jobs[candidate.id] = GitHubUpdateDownloadJob(
                    progress: nil,
                    bytesWritten: self.jobs[candidate.id]?.bytesWritten ?? 0,
                    totalBytesExpected: self.jobs[candidate.id]?.totalBytesExpected,
                    isDownloading: false,
                    queuedIPA: self.jobs[candidate.id]?.queuedIPA,
                    errorMessage: message
                )
            }
            if self.generations[candidate.id] == generation {
                self.tasks[candidate.id] = nil
                self.generations[candidate.id] = nil
            }
        }
    }

    func removeJob(for candidate: GitHubUpdateCandidate) {
        generations[candidate.id] = nil
        tasks[candidate.id]?.cancel()
        tasks[candidate.id] = nil
        jobs[candidate.id] = nil
    }

    /// Blocks new work, cancels and joins in-flight downloads, then removes
    /// their queued IPA records. A failed cleanup remains blocked for retry.
    func prepareForgettingGuest(targetID: String, ipaImportStore: IPAImportStore) async throws {
        forgettingGuestTargets.insert(targetID)
        let prefix = targetID + ":"
        let identifiers = Set(tasks.keys).union(jobs.keys).filter { $0.hasPrefix(prefix) }
        for identifier in identifiers {
            generations[identifier] = nil
            let task = tasks[identifier]
            if let task {
                task.cancel()
                await task.value
            }
            tasks[identifier] = nil
            jobs[identifier] = nil
        }
        try await ipaImportStore.deleteQueuedUpdates(forGuestTargetID: targetID)
    }

    func cancelDownload(for candidate: GitHubUpdateCandidate) {
        tasks[candidate.id]?.cancel()
    }

    func validateQueuedFiles(ipaImportStore: IPAImportStore) async {
        for (identifier, job) in jobs where !job.isDownloading {
            guard let ipa = job.queuedIPA else { continue }
            let available = await ipaImportStore.isManagedIPAAvailable(ipa)
            guard !available, jobs[identifier]?.queuedIPA == ipa, tasks[identifier] == nil else { continue }
            var updated = job
            updated.queuedIPA = nil
            updated.errorMessage = "The downloaded IPA is missing. Download it again to continue."
            jobs[identifier] = updated
        }
    }

    func restoreQueuedFiles(for candidates: [GitHubUpdateCandidate], ipaImportStore: IPAImportStore) async {
        guard let imports = try? await ipaImportStore.importedApps() else { return }
        for candidate in candidates {
            guard jobs[candidate.id] == nil,
                  let ipa = imports.first(where: {
                      $0.githubSourceIdentity == candidate.sourceIdentity && $0.queuedForInstalledAppID == candidate.bundleIdentifier && $0.githubUpdateKey == candidate.updateKey && $0.githubRepositoryURL == candidate.repositoryURL
                  }) else { continue }
            let available = await ipaImportStore.isManagedIPAAvailable(ipa)
            guard jobs[candidate.id] == nil else { continue }
            jobs[candidate.id] = GitHubUpdateDownloadJob(
                progress: available ? 1 : nil,
                bytesWritten: 0,
                totalBytesExpected: nil,
                isDownloading: false,
                queuedIPA: available ? ipa : nil,
                errorMessage: available ? nil : "The downloaded IPA is missing. Download it again to continue."
            )
        }
    }

    private func setProgress(_ downloadProgress: GitHubDownloadProgress, for identifier: String) {
        guard var job = jobs[identifier], job.isDownloading else { return }
        job.progress = downloadProgress.fractionCompleted
        job.bytesWritten = downloadProgress.bytesWritten
        job.totalBytesExpected = downloadProgress.totalBytesExpected
        jobs[identifier] = job
    }
}
