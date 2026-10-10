import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct GitHubHistoryPage: Sendable {
    var builds: [GitHubTrackedBuild]
    let hasMore: Bool
    var newerBuildHasNoDownload = false
}

enum GitHubHistoryError: LocalizedError {
    case invalidSource, unauthorized, unavailable(Int), ambiguousAsset, invalidResponse, paginationLimit
    var errorDescription: String? {
        switch self {
        case .invalidSource: "Check the GitHub repository and workflow settings."
        case .unauthorized: "GitHub rejected this token. Reconnect or select a token with repository and Actions read access."
        case .unavailable(let code): "GitHub could not complete this check (HTTP \(code)). Retry or check permissions and rate limits."
        case .ambiguousAsset: "More than one download matches. Choose an exact asset or artifact name in the update source settings."
        case .invalidResponse: "GitHub returned incomplete build information. The installed marker has not changed."
        case .paginationLimit: "This source has too many artifact pages for one check. Choose a more specific source and retry."
        }
    }
}

actor GitHubHistoryClient {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport
    init(transport: @escaping Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubHistoryError.invalidResponse }
        return (data, http)
    }) { self.transport = transport }

    private struct Release: Decodable {
        let id: Int64
        let tag_name: String
        let name: String?
        let draft: Bool?
        let published_at: String?
        let assets: [Asset]
    }
    private struct Asset: Decodable {
        let id: Int64
        let name: String
        let url: URL
        let state: String?
        let digest: String?
        let updated_at: String?
    }
    private struct Runs: Decodable { let workflow_runs: [Run] }
    private struct Run: Decodable {
        let id: Int64
        let run_number: Int64
        let run_attempt: Int64?
        let name: String?
        let display_title: String?
        let head_branch: String
        let conclusion: String?
        let created_at: String?
    }
    private struct Artifacts: Decodable { let artifacts: [Artifact] }
    private struct Artifact: Decodable {
        let id: Int64
        let name: String
        let expired: Bool
        let archive_download_url: URL
        let digest: String?
        let updated_at: String?
    }

    func page(configuration: GitHubUpdateConfiguration, token: String?, page: Int, allowMultiple: Bool = false) async throws -> GitHubHistoryPage {
        guard page > 0, let url = URL(string: configuration.repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["github.com", "www.github.com"].contains(url.host?.lowercased() ?? ""),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw GitHubHistoryError.invalidSource }
        let repository = GitHubSourceIdentity.repository(configuration.repositoryURL)
        let parts = URL(string: repository)!.path.split(separator: "/")
        guard parts.count == 2, parts.allSatisfy({ $0.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil }) else { throw GitHubHistoryError.invalidSource }
        let root = "/repos/" + parts.joined(separator: "/")
        if configuration.source == .latestRelease {
            let releases: [Release] = try await get(path: root + "/releases", query: ["per_page": "100", "page": String(page)], token: token)
            var builds: [GitHubTrackedBuild] = []
            var pending = false
            for release in releases where release.draft != true {
                let eligible = release.assets.filter { $0.name.lowercased().hasSuffix(".ipa") && ($0.state == nil || $0.state == "uploaded") }
                var matches = select(eligible, name: { $0.name }, filter: configuration.assetName)
                if matches.count > 1 && !allowMultiple {
                    guard Set(matches.map { $0.name.lowercased() }).count == 1 else { throw GitHubHistoryError.ambiguousAsset }
                    matches = Array(matches.sorted(by: { $0.id > $1.id }).prefix(1))
                }
                if matches.isEmpty && builds.isEmpty { pending = true }
                for asset in matches {
                    let revision = Data((asset.digest ?? asset.updated_at ?? "").utf8).base64EncodedString()
                    builds.append(GitHubTrackedBuild(key: "release-v2:\(release.id):\(asset.id):\(revision)",
                        title: release.name ?? release.tag_name, version: release.tag_name,
                        assetName: asset.name, downloadURL: asset.url, date: date(release.published_at)))
                }
            }
            return GitHubHistoryPage(builds: builds, hasMore: releases.count == 100, newerBuildHasNoDownload: pending)
        }
        let workflow = configuration.workflowFile.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ".github/workflows/", with: "")
        guard !workflow.isEmpty, let encoded = workflow.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) else { throw GitHubHistoryError.invalidSource }
        let branch = configuration.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        var query = ["status": "success", "per_page": "10", "page": String(page)]
        if !branch.isEmpty && branch != "*" { query["branch"] = branch }
        let runs: Runs = try await get(path: root + "/actions/workflows/" + encoded + "/runs", query: query, token: token)
        var builds: [GitHubTrackedBuild] = []
        var pending = false
        for run in runs.workflow_runs.sorted(by: { $0.run_number > $1.run_number }) where run.conclusion == "success" && (branch.isEmpty || branch == "*" || run.head_branch == branch) {
            var all: [Artifact] = []
            var artifactPage = 1
            while true {
                try Task.checkCancellation()
                let result: Artifacts = try await get(path: root + "/actions/runs/\(run.id)/artifacts", query: ["per_page": "100", "page": String(artifactPage)], token: token)
                all += result.artifacts.filter { !$0.expired }
                if result.artifacts.count < 100 { break }
                artifactPage += 1
                guard artifactPage <= 20 else { throw GitHubHistoryError.paginationLimit }
            }
            var matches = select(all, name: { $0.name }, filter: configuration.assetName)
            if matches.count > 1 && !allowMultiple {
                    guard Set(matches.map { $0.name.lowercased() }).count == 1 else { throw GitHubHistoryError.ambiguousAsset }
                    matches = Array(matches.sorted(by: { $0.id > $1.id }).prefix(1))
                }
            if matches.isEmpty && builds.isEmpty { pending = true }
            for artifact in matches.sorted(by: { $0.id > $1.id }) {
                let revision = Data((artifact.digest ?? artifact.updated_at ?? "").utf8).base64EncodedString()
                let title = run.display_title ?? run.name ?? "GitHub Actions"
                builds.append(GitHubTrackedBuild(key: "actions-v2:\(run.id):\(run.run_number):\(run.run_attempt ?? 1):\(artifact.id):\(revision)",
                    title: "Build \(run.run_number) - \(title)", version: "Build \(run.run_number)",
                    assetName: artifact.name, downloadURL: artifact.archive_download_url, date: date(run.created_at)))
            }
        }
        return GitHubHistoryPage(builds: builds, hasMore: runs.workflow_runs.count == 10, newerBuildHasNoDownload: pending)
    }

    private func select<T>(_ values: [T], name: (T) -> String, filter: String) -> [T] {
        let filter = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filter.isEmpty else { return values }
        if !filter.contains("*") {
            let exact = values.filter { name($0).caseInsensitiveCompare(filter) == .orderedSame }
            return exact.isEmpty ? values.filter { name($0).localizedCaseInsensitiveContains(filter) } : exact
        }
        let pattern = "^" + filter.components(separatedBy: "*").map(NSRegularExpression.escapedPattern(for:)).joined(separator: ".*") + "$"
        return values.filter { name($0).range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
    }
    private func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    private func get<T: Decodable>(path: String, query: [String: String], token: String?) async throws -> T {
        try Task.checkCancellation()
        var components = URLComponents(string: "https://api.github.com")!
        components.percentEncodedPath = path
        components.queryItems = query.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SideKick", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await transport(request)
        if response.statusCode == 401 { throw GitHubHistoryError.unauthorized }
        guard (200..<300).contains(response.statusCode) else { throw GitHubHistoryError.unavailable(response.statusCode) }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw GitHubHistoryError.invalidResponse }
    }
}
