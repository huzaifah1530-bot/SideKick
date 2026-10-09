import Foundation
import Observation

struct GitHubUpdateDownloadJob: Equatable {
    var progress: Double?
    var isDownloading: Bool
    var queuedIPA: ImportedIPA?
    var errorMessage: String?
}

@MainActor
@Observable
final class GitHubUpdateDownloadStore {
    private(set) var jobs: [String: GitHubUpdateDownloadJob] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    func start(
        candidate: GitHubUpdateCandidate,
        expectedBundleIdentifiers: Set<String>,
        ipaImportStore: IPAImportStore,
        token: String?
    ) {
        guard tasks[candidate.id] == nil else { return }
        jobs[candidate.id] = GitHubUpdateDownloadJob(
            progress: 0,
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
                        self.setProgress(progress, for: candidate.id)
                    }
                }
                temporaryURL = downloaded
                let queuedIPA = try await ipaImportStore.importManagedIPA(
                    from: downloaded,
                    expectedBundleIdentifiers: expectedBundleIdentifiers
                )
                self.jobs[candidate.id] = GitHubUpdateDownloadJob(
                    progress: 1,
                    isDownloading: false,
                    queuedIPA: queuedIPA,
                    errorMessage: nil
                )
            } catch {
                self.jobs[candidate.id] = GitHubUpdateDownloadJob(
                    progress: nil,
                    isDownloading: false,
                    queuedIPA: nil,
                    errorMessage: error.localizedDescription
                )
            }
            if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
            self.tasks[candidate.id] = nil
        }
    }

    func removeJob(for candidate: GitHubUpdateCandidate) {
        tasks[candidate.id]?.cancel()
        tasks[candidate.id] = nil
        jobs[candidate.id] = nil
    }

    private func setProgress(_ progress: Double?, for identifier: String) {
        guard var job = jobs[identifier], job.isDownloading else { return }
        job.progress = progress
        jobs[identifier] = job
    }
}
