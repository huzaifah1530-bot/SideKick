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

    func start(
        candidate: GitHubUpdateCandidate,
        expectedBundleIdentifiers: Set<String>,
        ipaImportStore: IPAImportStore,
        token: String?
    ) {
        guard tasks[candidate.id] == nil else { return }
        let generation = UUID()
        generations[candidate.id] = generation
        jobs[candidate.id] = GitHubUpdateDownloadJob(
            progress: nil,
            bytesWritten: 0,
            totalBytesExpected: nil,
            isDownloading: true,
            queuedIPA: nil,
            errorMessage: nil
        )

        tasks[candidate.id] = Task { [weak self] in
            guard let self else { return }
            var temporaryURL: URL?
            do {
                let downloaded = try await GitHubUpdateService().downloadIPA(for: candidate, token: token) { progress in
                    Task { @MainActor in
                        if self.generations[candidate.id] == generation { self.setProgress(progress, for: candidate.id) }
                    }
                }
                temporaryURL = downloaded
                defer { try? FileManager.default.removeItem(at: downloaded) }
                try Task.checkCancellation()
                let queuedIPA = try await ipaImportStore.importManagedIPA(
                    from: downloaded,
                    expectedBundleIdentifiers: expectedBundleIdentifiers,
                    updateKey: candidate.updateKey,
                    repositoryURL: candidate.repositoryURL
                )
                guard self.generations[candidate.id] == generation else { return }
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
                self.jobs[candidate.id] = GitHubUpdateDownloadJob(
                    progress: nil,
                    bytesWritten: self.jobs[candidate.id]?.bytesWritten ?? 0,
                    totalBytesExpected: self.jobs[candidate.id]?.totalBytesExpected,
                    isDownloading: false,
                    queuedIPA: nil,
                    errorMessage: error.localizedDescription
                )
            }
            if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
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
                      $0.githubUpdateKey == candidate.updateKey && $0.githubRepositoryURL == candidate.repositoryURL
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
