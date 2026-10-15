import Foundation

/// The same discovery policy serves automatic scans and app details.
enum GitHubUpdateDiscovery {
    static func check(for target: GitHubUpdateTarget, configuration: GitHubUpdateConfiguration,
                      token: String?, forceRefresh: Bool = true,
                      historyStore: GitHubHistoryStore = .shared) async throws -> GitHubCheckResult {
        var history: [GitHubTrackedBuild] = []
        var missingNewerDownload = false
        var fetchedAt: Date?
        for page in 1...5 {
            try Task.checkCancellation()
            let result = try await historyStore.page(configuration: configuration, token: token, page: page,
                forceRefresh: forceRefresh && page == 1, latestOnly: true)
            history += result.builds
            if page == 1 { fetchedAt = result.fetchedAt }
            missingNewerDownload = missingNewerDownload || result.newerBuildHasNoDownload
            if !history.isEmpty || !result.hasMore { break }
        }
        var result = GitHubTrackingPolicy.check(target: target, configuration: configuration, history: history)
        result.checkedAt = fetchedAt
        if result.state == .current && missingNewerDownload {
            result = GitHubCheckResult(targetID: target.id, state: .noMatchingDownload,
                detail: "A more recent successful build has no matching downloadable file yet.",
                latestBuild: history.first, checkedAt: fetchedAt)
        }
        return result
    }
}
