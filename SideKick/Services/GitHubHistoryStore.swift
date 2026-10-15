import Foundation

/// App-session history shared by automatic checks and version screens. Credentials
/// stay in memory, never in diagnostics or on disk. Downloads still authenticate.
actor GitHubHistoryStore {
    typealias Loader = @Sendable (GitHubUpdateConfiguration, String?, Int, Bool) async throws -> GitHubHistoryPage
    static let shared = GitHubHistoryStore()
    private struct Key: Hashable {
        let source: String
        let token: String?
        let page: Int
        // Discovery stops at the newest download; version lists need the complete page.
        let latestOnly: Bool
    }
    private struct Entry {
        let value: GitHubHistoryPage
        let fetchedAt: Date
    }
    private let lifetime: TimeInterval
    private let loader: Loader
    private var entries: [Key: Entry] = [:]
    private var requests: [Key: Task<GitHubHistoryPage, Error>] = [:]

    init(lifetime: TimeInterval = 300, loader: @escaping Loader = { configuration, token, page, latestOnly in
        try await GitHubHistoryClient().page(configuration: configuration, token: token, page: page, latestOnly: latestOnly)
    }) {
        self.lifetime = lifetime
        self.loader = loader
    }

    func page(configuration: GitHubUpdateConfiguration, token: String?, page: Int,
              forceRefresh: Bool = false, latestOnly: Bool = false) async throws -> GitHubHistoryPage {
        let key = Key(source: configuration.sourceIdentity, token: token, page: page, latestOnly: latestOnly)
        if let request = requests[key] { return try await request.value }
        if !forceRefresh, let entry = entries[key], Date.now.timeIntervalSince(entry.fetchedAt) < lifetime {
            await GitHubDiagnosticsStore.shared.record(.cacheHit, repository: configuration.repositoryURL, authenticated: token?.isEmpty == false)
            return entry.value
        }
        let loader = self.loader
        let request = Task {
            var result = try await loader(configuration, token, page, latestOnly)
            result.fetchedAt = .now
            return result
        }
        requests[key] = request
        defer { requests[key] = nil }
        let result = try await request.value
        // A failed refresh must not erase usable session history. Invalidate
        // subsequent pages only after the first page successfully reloads.
        if forceRefresh, page == 1 {
            entries = entries.filter { $0.key.source != key.source || $0.key.token != key.token }
        }
        entries = entries.filter { Date.now.timeIntervalSince($0.value.fetchedAt) < lifetime }
        if entries.count >= 64, let oldest = entries.min(by: { $0.value.fetchedAt < $1.value.fetchedAt }) {
            entries[oldest.key] = nil
        }
        entries[key] = Entry(value: result, fetchedAt: .now)
        return result
    }
}
