import Foundation
import ZIPFoundation

actor GitHubUpdateService {
    private struct GitHubUser: Decodable { let login: String }
    private struct Release: Decodable {
        let id: Int
        let tag_name: String
        let name: String?
        let published_at: String?
        let assets: [ReleaseAsset]
    }
    private struct ReleaseAsset: Decodable {
        let name: String
        let url: URL
    }
    private struct WorkflowRuns: Decodable { let workflow_runs: [WorkflowRun] }
    private struct WorkflowRun: Decodable {
        let id: Int
        let run_number: Int
        let name: String?
        let display_title: String?
        let head_branch: String
        let conclusion: String?
        let created_at: String?
    }
    private struct Artifacts: Decodable { let artifacts: [Artifact] }
    private struct Artifact: Decodable {
        let id: Int
        let name: String
        let expired: Bool
        let archive_download_url: URL
    }

    struct Repository: Decodable, Sendable { let default_branch: String }
    struct Workflow: Decodable, Identifiable, Sendable {
        let id: Int
        let name: String
        let path: String
    }
    private struct Workflows: Decodable { let workflows: [Workflow] }

    func repositoryInfo(_ url: String, token: String?) async throws -> Repository {
        let repo = try parseRepository(url)
        return try await fetch(apiRequest(path: "/repos/\(repo.owner)/\(repo.name)", token: token))
    }

    func workflows(_ url: String, token: String?, page: Int) async throws -> [Workflow] {
        let repo = try parseRepository(url)
        let result: Workflows = try await fetch(apiRequest(path: "/repos/\(repo.owner)/\(repo.name)/actions/workflows?per_page=100&page=\(page)", token: token))
        return result.workflows
    }

    func importChoices(repositoryURL: String, source: GitHubUpdateSource, workflow: String, branch: String, token: String?, page: Int) async throws -> GitHubImportPage {
        let repo = try parseRepository(repositoryURL)
        let canonicalURL = "https://github.com/\(repo.owner)/\(repo.name)"
        func choice(key: String, title: String, version: String, name: String, url: URL, date: String?) -> GitHubImportChoice {
            GitHubImportChoice(candidate: GitHubUpdateCandidate(
                bundleIdentifier: "", appName: title, currentVersion: "", newVersion: version,
                title: title, assetName: name, downloadURL: url, updateKey: key,
                source: source, repositoryURL: canonicalURL
            ), workflow: workflow, branch: branch, date: parseGitHubDate(date))
        }
        if source == .latestRelease {
            let releases: [Release] = try await fetch(apiRequest(path: "/repos/\(repo.owner)/\(repo.name)/releases?per_page=100&page=\(page)", token: token))
            let choices = releases.flatMap { release in
                release.assets.filter { $0.name.lowercased().hasSuffix(".ipa") }.map { asset in
                    choice(key: "release:\(release.id):\(release.tag_name):\(asset.name)", title: release.name ?? release.tag_name, version: release.tag_name, name: asset.name, url: asset.url, date: release.published_at)
                }
            }
            return GitHubImportPage(choices: choices, hasMore: releases.count == 100)
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let workflowPath = workflow.addingPercentEncoding(withAllowedCharacters: allowed),
              let branchQuery = branch.addingPercentEncoding(withAllowedCharacters: allowed) else { throw GitHubUpdateError.invalidRepository }
        let runs: WorkflowRuns = try await fetch(apiRequest(path: "/repos/\(repo.owner)/\(repo.name)/actions/workflows/\(workflowPath)/runs?branch=\(branchQuery)&status=success&per_page=10&page=\(page)", token: token))
        var choices: [GitHubImportChoice] = []
        for run in runs.workflow_runs where run.conclusion == "success" && run.head_branch == branch {
            try Task.checkCancellation()
            var artifactPage = 1
            while true {
                let artifacts: Artifacts = try await fetch(apiRequest(path: "/repos/\(repo.owner)/\(repo.name)/actions/runs/\(run.id)/artifacts?per_page=100&page=\(artifactPage)", token: token))
                choices += artifacts.artifacts.filter { !$0.expired }.map { artifact in
                    choice(key: "actions:\(run.id):\(artifact.id)", title: "Build \(run.run_number) · \(run.display_title ?? run.name ?? "Build")", version: "Build \(run.run_number)", name: artifact.name, url: artifact.archive_download_url, date: run.created_at)
                }
                if artifacts.artifacts.count < 100 { break }
                artifactPage += 1
            }
        }
        return GitHubImportPage(choices: choices, hasMore: runs.workflow_runs.count == 10)
    }

    func candidate(for app: InstalledAppSummary, configuration: GitHubUpdateConfiguration, token: String? = nil) async throws -> GitHubUpdateCandidate? {
        let repository = try parseRepository(configuration.repositoryURL)
        switch configuration.source {
        case .latestRelease:
            let history = try await releaseHistory(owner: repository.owner, name: repository.name, assetName: configuration.assetName, token: token)
            return candidate(from: history, for: app, configuration: configuration)
        case .actionsArtifact:
            let history = try await actionsHistory(owner: repository.owner, name: repository.name, configuration: configuration, token: token)
            return candidate(from: history, for: app, configuration: configuration)
        }
    }

    func history(for configuration: GitHubUpdateConfiguration, token: String? = nil) async throws -> [GitHubUpdateHistoryEntry] {
        let repository = try parseRepository(configuration.repositoryURL)
        switch configuration.source {
        case .latestRelease:
            return try await releaseHistory(owner: repository.owner, name: repository.name, assetName: configuration.assetName, token: token)
                .map(\.entry)
        case .actionsArtifact:
            return try await actionsHistory(owner: repository.owner, name: repository.name, configuration: configuration, token: token)
                .map(\.entry)
        }
    }

    private struct UpdateItem {
        let entry: GitHubUpdateHistoryEntry
        let version: String
        let title: String
        let assetName: String
        let url: URL
    }

    private func matchesAsset(_ name: String, filter: String) -> Bool {
        guard !filter.isEmpty else { return true }
        if !filter.contains("*") { return name.localizedCaseInsensitiveContains(filter) }
        let pattern = "^" + filter.components(separatedBy: "*").map(NSRegularExpression.escapedPattern(for:)).joined(separator: ".*") + "$"
        return name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func releaseHistory(owner: String, name: String, assetName: String, token: String?) async throws -> [UpdateItem] {
        var request = apiRequest(path: "/repos/\(owner)/\(name)/releases?per_page=100", token: token)
        request.httpMethod = "GET"
        let releases: [Release] = try await fetch(request)
        return releases.compactMap { release in
            guard let asset = release.assets.first(where: {
                $0.name.lowercased().hasSuffix(".ipa")
                    && matchesAsset($0.name, filter: assetName)
            }) else { return nil }
            let key = "release:\(release.id):\(release.tag_name):\(asset.name)"
            return UpdateItem(
                entry: GitHubUpdateHistoryEntry(key: key, title: release.name ?? release.tag_name, date: parseGitHubDate(release.published_at)),
                version: release.tag_name, title: release.name ?? release.tag_name, assetName: asset.name, url: asset.url
            )
        }
    }

    private func actionsHistory(owner: String, name: String, configuration: GitHubUpdateConfiguration, token: String?) async throws -> [UpdateItem] {
        let componentCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let workflow = configuration.workflowFile.addingPercentEncoding(withAllowedCharacters: componentCharacters) ?? configuration.workflowFile
        let branch = configuration.branch.addingPercentEncoding(withAllowedCharacters: componentCharacters) ?? configuration.branch
        var request = apiRequest(path: "/repos/\(owner)/\(name)/actions/workflows/\(workflow)/runs?branch=\(branch)&status=success&per_page=10", token: token)
        request.httpMethod = "GET"
        let runs: WorkflowRuns = try await fetch(request)
        var items: [UpdateItem] = []
        for run in runs.workflow_runs where run.conclusion == "success" && run.head_branch == configuration.branch {
            var artifactRequest = apiRequest(path: "/repos/\(owner)/\(name)/actions/runs/\(run.id)/artifacts?per_page=100", token: token)
            artifactRequest.httpMethod = "GET"
            let artifacts: Artifacts = try await fetch(artifactRequest)
            guard let artifact = artifacts.artifacts.first(where: {
                !$0.expired && matchesAsset($0.name, filter: configuration.assetName)
            }) else { continue }
            let key = "actions:\(run.id):\(artifact.id)"
            let title = run.name ?? run.display_title ?? "Successful GitHub Actions build"
            items.append(UpdateItem(
                entry: GitHubUpdateHistoryEntry(key: key, title: "Build \(run.run_number) · \(title)", date: parseGitHubDate(run.created_at)),
                version: "Build \(run.run_number)", title: title, assetName: artifact.name, url: artifact.archive_download_url
            ))
        }
        return items
    }

    private func candidate(from history: [UpdateItem], for app: InstalledAppSummary, configuration: GitHubUpdateConfiguration) -> GitHubUpdateCandidate? {
        let baselineKey = configuration.lastInstalledUpdateKey ?? configuration.baselineUpdateKey
        guard let baselineKey, let item = history.first else { return nil }
        if let index = history.firstIndex(where: {
            $0.entry.key == baselineKey || legacyReleaseKey(for: $0.entry.key) == baselineKey
        }) {
            guard index > 0 else { return nil }
        } else {
            // Actions artifacts can expire and an old baseline can leave the
            // returned history. GitHub IDs preserve the ordering of these runs.
            let baseline = baselineKey.split(separator: ":")
            let latest = item.entry.key.split(separator: ":")
            guard baseline.count >= 3, latest.count >= 3,
                  baseline[0] == latest[0], let previousID = Int64(baseline[1]),
                  let latestID = Int64(latest[1]), latestID > previousID else { return nil }
        }
        guard item.entry.key != configuration.dismissedUpdateKey else { return nil }
        guard item.entry.key != baselineKey else { return nil }
        return GitHubUpdateCandidate(
            bundleIdentifier: app.bundleIdentifier, appName: app.name, currentVersion: app.version,
            newVersion: item.version, title: item.title, assetName: item.assetName,
            downloadURL: item.url, updateKey: item.entry.key, source: configuration.source,
            repositoryURL: configuration.repositoryURL
        )
    }

    private func legacyReleaseKey(for currentKey: String) -> String? {
        let parts = currentKey.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "release" else { return nil }
        return "release:\(parts[2]):\(parts[3])"
    }

    private func parseGitHubDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    func validateToken(_ token: String) async throws -> String {
        let request = apiRequest(path: "/user", token: token)
        let user: GitHubUser = try await fetch(request)
        return user.login
    }

    func downloadIPA(
        for candidate: GitHubUpdateCandidate,
        token: String? = nil,
        onProgress: @escaping @Sendable (GitHubDownloadProgress) -> Void = { _ in }
    ) async throws -> URL {
        guard candidate.downloadURL.scheme == "https", candidate.downloadURL.host == "api.github.com" else {
            throw GitHubUpdateError.invalidRepository
        }
        var request = URLRequest(url: candidate.downloadURL)
        request.setValue(candidate.source == .latestRelease ? "application/octet-stream" : "application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SideKick iOS app", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let delegate = GitHubDownloadProgressDelegate(onProgress: onProgress)
        let (downloadURL, response) = try await URLSession.shared.download(for: request, delegate: delegate)
        guard let response = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: downloadURL)
            throw GitHubUpdateError.downloadFailed
        }
        guard (200..<300).contains(response.statusCode) else {
            try? FileManager.default.removeItem(at: downloadURL)
            throw error(for: response)
        }
        if candidate.source == .latestRelease {
            return downloadURL
        }

        defer { try? FileManager.default.removeItem(at: downloadURL) }
        let archive: Archive
        do { archive = try Archive(url: downloadURL, accessMode: .read) }
        catch {
            try? FileManager.default.removeItem(at: downloadURL)
            throw GitHubUpdateError.invalidArtifact
        }
        let ipaEntries = archive.filter { $0.path.lowercased().hasSuffix(".ipa") }
        guard ipaEntries.count <= 1 else {
            try? FileManager.default.removeItem(at: downloadURL)
            throw GitHubUpdateError.multipleIPAsInArtifact
        }
        guard let ipaEntry = ipaEntries.first else {
            try? FileManager.default.removeItem(at: downloadURL)
            throw GitHubUpdateError.noIPAInArtifact
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidekick-github-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
            .appendingPathExtension("ipa")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle: FileHandle
        do { handle = try FileHandle(forWritingTo: output) }
        catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        do {
            _ = try archive.extract(ipaEntry) { chunk in try handle.write(contentsOf: chunk) }
            try handle.close()
            try FileManager.default.removeItem(at: downloadURL)
            return output
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: downloadURL)
            throw GitHubUpdateError.invalidArtifact
        }
    }

    private func apiRequest(path: String, token: String?) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.github.com\(path)")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SideKick iOS app", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func fetch<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw GitHubUpdateError.unavailable }
        guard (200..<300).contains(response.statusCode) else {
            throw error(for: response)
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw GitHubUpdateError.invalidResponse }
    }

    private func error(for response: HTTPURLResponse) -> GitHubUpdateError {
        switch response.statusCode {
        case 401:
            return .invalidToken
        case 403:
            if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
                || response.value(forHTTPHeaderField: "Retry-After") != nil {
                return .rateLimited
            }
            return .insufficientPermissions(response.value(forHTTPHeaderField: "X-Accepted-GitHub-Permissions"))
        case 404:
            return .notFound
        default:
            return .unavailable
        }
    }

    private func parseRepository(_ value: String) throws -> (owner: String, name: String) {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["github.com", "www.github.com"].contains(url.host?.lowercased() ?? "") else { throw GitHubUpdateError.invalidRepository }
        let pieces = url.path.split(separator: "/").map(String.init)
        guard pieces.count >= 2 else { throw GitHubUpdateError.invalidRepository }
        let name = pieces[1].hasSuffix(".git") ? String(pieces[1].dropLast(4)) : pieces[1]
        guard [pieces[0], name].allSatisfy({
            $0.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil
        }) else { throw GitHubUpdateError.invalidRepository }
        return (pieces[0], name)
    }

}

private final class GitHubDownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (GitHubDownloadProgress) -> Void

    init(onProgress: @escaping @Sendable (GitHubDownloadProgress) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https" else { completionHandler(nil); return }
        var redirected = request
        if request.url?.host != "api.github.com" {
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(redirected)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress(GitHubDownloadProgress(
            bytesWritten: totalBytesWritten,
            totalBytesExpected: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        ))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) { }
}

struct GitHubDownloadProgress: Sendable {
    let bytesWritten: Int64
    let totalBytesExpected: Int64?

    var fractionCompleted: Double? {
        guard let totalBytesExpected, totalBytesExpected > 0 else { return nil }
        return min(max(Double(bytesWritten) / Double(totalBytesExpected), 0), 1)
    }
}

enum GitHubUpdateError: LocalizedError {
    case invalidRepository, invalidToken, notFound, insufficientPermissions(String?), rateLimited, unavailable, invalidResponse, downloadFailed, invalidArtifact, noIPAInArtifact, multipleIPAsInArtifact
    var errorDescription: String? {
        switch self {
        case .invalidRepository: "Enter a GitHub repository URL, such as https://github.com/owner/repository."
        case .invalidToken: "GitHub rejected this token. Check that it’s valid and has the required read-only repository and Actions access."
        case .notFound: "GitHub couldn’t find that repository, release, workflow, or artifact. For a private repository, check that this token was created for its owner, includes this repository, and has been approved by the organization."
        case .insufficientPermissions(let permissions):
            "GitHub denied access to this resource. Grant the token the required read permission\(permissions.map { ": \($0)" } ?? " for the selected repository")."
        case .rateLimited: "GitHub temporarily limited update checks. Try again later."
        case .unavailable: "GitHub is temporarily unavailable. Try again later."
        case .invalidResponse: "GitHub returned update information SideKick couldn’t read."
        case .downloadFailed: "SideKick couldn’t download the GitHub update."
        case .invalidArtifact: "The GitHub Actions artifact is damaged or isn’t a valid ZIP archive."
        case .multipleIPAsInArtifact: "This artifact contains multiple IPAs. Choose an artifact containing only the app you want, or import its IPA directly."
        case .noIPAInArtifact: "No IPA file was found in that GitHub download."
        }
    }
}

struct GitHubImportPage: Sendable {
    let choices: [GitHubImportChoice]
    let hasMore: Bool
}

struct GitHubImportChoice: Identifiable, Sendable {
    var id: String { candidate.updateKey }
    let candidate: GitHubUpdateCandidate
    let workflow: String
    let branch: String
    let date: Date?

    func configuration(bundleIdentifier: String, tokenID: String?) -> GitHubUpdateConfiguration {
        var assetFilter = candidate.assetName
        if candidate.source == .latestRelease {
            let tag = candidate.newVersion
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            if version.contains("."), assetFilter.contains(version) {
                assetFilter = assetFilter.replacingOccurrences(of: version, with: "*")
            }
        }
        return GitHubUpdateConfiguration(bundleIdentifier: bundleIdentifier,
            repositoryURL: candidate.repositoryURL ?? "", source: candidate.source,
            workflowFile: workflow, branch: branch, assetName: assetFilter,
            baselineUpdateKey: candidate.updateKey, lastInstalledUpdateKey: candidate.updateKey,
            tokenID: tokenID)
    }
}
