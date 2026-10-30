import Foundation
import Observation

/// Downloads started from Import from URL or Install from GitHub. They live here, not in the
/// view, so they keep running after you leave the page and can be reopened from the floating
/// downloads button.
@MainActor
@Observable
final class IPAImportDownloadStore {
    enum Source {
        case url(URL)
        case repository(GitHubImportChoice, tokenID: String?)
    }

    enum State: Equatable {
        case downloading
        /// The IPA matches installed apps; the user picks which one it updates.
        case needsTarget(ImportedIPA, [InstalledAppSummary])
        case ready(ImportedIPA, isUpdate: Bool)
        case failed(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.downloading, .downloading): true
            case let (.needsTarget(a, x), .needsTarget(b, y)): a == b && x.map(\.id) == y.map(\.id)
            case let (.ready(a, u), .ready(b, v)): a == b && u == v
            case let (.failed(a), .failed(b)): a == b
            default: false
            }
        }
    }

    struct Job: Identifiable {
        let id: UUID
        let title: String
        let source: Source
        var state: State = .downloading
        var progress: GitHubDownloadProgress?
    }

    private(set) var jobs: [UUID: Job] = [:]
    private(set) var order: [UUID] = []
    /// The job whose page is on screen; the floating button hides it.
    var visibleJobID: UUID?
    var reviewRequestedJobID: UUID?
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var choicesInFlight: Set<UUID> = []
    @ObservationIgnored private let ipaStore: IPAImportStore

    init(ipaStore: IPAImportStore) { self.ipaStore = ipaStore }

    /// Shown in the floating button: still downloading, or waiting for a decision.
    var activeJobIDs: [UUID] {
        order.filter { id in
            guard id != visibleJobID, let job = jobs[id] else { return false }
            switch job.state {
            case .downloading, .needsTarget: return true
            case .ready, .failed: return false
            }
        }
    }

    @discardableResult
    func start(_ source: Source) -> UUID {
        let id = UUID()
        let title: String
        switch source {
        case .url(let url): title = url.lastPathComponent.isEmpty ? (url.host ?? "Download") : url.lastPathComponent
        case .repository(let choice, _): title = choice.candidate.title
        }
        jobs[id] = Job(id: id, title: title, source: source)
        order.append(id)
        tasks[id] = Task { [weak self] in await self?.run(id) }
        return id
    }

    /// While downloading: stops. After: deletes the IPA. Either way the job is forgotten.
    func cancel(_ id: UUID) async {
        guard !choicesInFlight.contains(id) else { return }
        if reviewRequestedJobID == id { reviewRequestedJobID = nil }
        tasks[id]?.cancel()
        tasks[id] = nil
        let state = jobs[id]?.state
        jobs[id] = nil
        order.removeAll { $0 == id }
        switch state {
        case .needsTarget(let ipa, _): await ipaStore.discardPreparedIPA(ipa)
        case .ready(let ipa, _): try? await ipaStore.delete(ipa)
        default: break
        }
    }

    /// Clears a finished or failed job from the list without touching the saved IPA.
    func dismiss(_ id: UUID) {
        guard tasks[id] == nil, !choicesInFlight.contains(id) else { return }
        jobs[id] = nil
        order.removeAll { $0 == id }
    }

    func choose(_ id: UUID, target: InstalledAppSummary?) async {
        guard !choicesInFlight.contains(id), case .needsTarget(let ipa, let installations) = jobs[id]?.state else { return }
        if let target, !installations.contains(where: { $0.id == target.id }) { return }
        choicesInFlight.insert(id)
        defer { choicesInFlight.remove(id) }
        do { jobs[id]?.state = .ready(try await save(ipa, targetID: target?.id, asSeparateApp: target == nil), isUpdate: target != nil) }
        catch {
            await ipaStore.discardPreparedIPA(ipa)
            fail(id, error)
        }
    }

    func retry(_ id: UUID) {
        guard let job = jobs[id], case .failed = job.state else { return }
        jobs[id]?.state = .downloading
        jobs[id]?.progress = nil
        tasks[id] = Task { [weak self] in await self?.run(id) }
    }

    // MARK: - Work

    private func run(_ id: UUID) async {
        guard let job = jobs[id] else { return }
        var prepared: ImportedIPA?
        do {
            switch job.source {
            case .url(let url):
                let (file, response) = try await BuzzheavierClient().download(from: url) { progress in
                    Task { @MainActor [weak self] in self?.jobs[id]?.progress = progress }
                }
                defer { try? FileManager.default.removeItem(at: file) }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw AppSharingError.downloadFailed(http.statusCode)
                }
                try Task.checkCancellation()
                prepared = try await ipaStore.prepareIPA(from: file, remoteSourceURL: url)
            case .repository(let choice, let tokenID):
                let token = try GitHubCredentialStore().load(id: tokenID)
                let file = try await GitHubUpdateService().downloadIPA(for: choice.candidate, token: token) { progress in
                    Task { @MainActor [weak self] in self?.jobs[id]?.progress = progress }
                }
                defer { try? FileManager.default.removeItem(at: file) }
                try Task.checkCancellation()
                prepared = try await ipaStore.importRepositoryIPA(from: file, choice: choice, tokenID: tokenID)
            }
            guard let ipa = prepared else { return }
            try Task.checkCancellation()
            let installed = try await SideStoreOperationService(accountStore: SigningAccountStore(), ipaStore: ipaStore)
                .loadInstalledApps()
            try Task.checkCancellation()
            guard jobs[id] != nil else { await ipaStore.discardPreparedIPA(ipa); return }
            let matches = installed.filter { $0.updateMatchingBundleIdentifiers.contains(ipa.bundleIdentifier.lowercased()) }
            if matches.isEmpty {
                jobs[id]?.state = .ready(try await save(ipa, targetID: nil), isUpdate: false)
            } else {
                jobs[id]?.state = .needsTarget(ipa, matches)
            }
        } catch {
            if let prepared { await ipaStore.discardPreparedIPA(prepared) }
            // Canceling removed the job already; nothing to report.
            if jobs[id] != nil, !Task.isCancelled, !(error is CancellationError) { fail(id, error) }
        }
        tasks[id] = nil
    }

    private func save(_ ipa: ImportedIPA, targetID: String?, asSeparateApp: Bool = false) async throws -> ImportedIPA {
        var saved = ipa
        saved.isQueuedForUpdate = targetID != nil
        saved.queuedForInstalledAppID = targetID
        saved.separateInstallationRequested = asSeparateApp
        try await ipaStore.saveImportedIPA(saved)
        return saved
    }

    private func fail(_ id: UUID, _ error: Error) {
        let message: String
        if let importError = error as? IPAImportError {
            switch importError {
            case .invalidArchive, .missingAppBundle, .ambiguousAppBundles, .missingBundleIdentifier, .notAnIPA:
                message = "That link returned a web page or a file that isn’t a valid IPA. Use a direct IPA download link."
            default:
                message = importError.localizedDescription
            }
        } else {
            message = error.localizedDescription
        }
        jobs[id]?.state = .failed(message)
    }
}
