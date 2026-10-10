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

    private func releaseHistory(owner: String, name: String, assetName: String, token: String?) async throws -> [UpdateItem] {
        var request = apiRequest(path: "/repos/\(owner)/\(name)/releases?per_page=100", token: token)
        request.httpMethod = "GET"
        let releases: [Release] = try await fetch(request)
        return releases.compactMap { release in
            guard let asset = release.assets.first(where: {
                $0.name.lowercased().hasSuffix(".ipa")
                    && (assetName.isEmpty || $0.name.localizedCaseInsensitiveContains(assetName))
            }) else { return nil }
            let key = "release:\(release.id):\(release.tag_name):\(asset.name)"
            return UpdateItem(
                entry: GitHubUpdateHistoryEntry(key: key, title: release.name ?? release.tag_name, date: parseGitHubDate(release.published_at)),
                version: release.tag_name, title: release.name ?? release.tag_name, assetName: asset.name, url: asset.url
            )
        }
    }

    private func actionsHistory(owner: String, name: String, configuration: GitHubUpdateConfiguration, token: String?) async throws -> [UpdateItem] {
        let workflow = configuration.workflowFile.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? configuration.workflowFile
        let branch = configuration.branch.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? configuration.branch
        var request = apiRequest(path: "/repos/\(owner)/\(name)/actions/workflows/\(workflow)/runs?branch=\(branch)&status=success&per_page=10", token: token)
        request.httpMethod = "GET"
        let runs: WorkflowRuns = try await fetch(request)
        var items: [UpdateItem] = []
        for run in runs.workflow_runs where run.conclusion == "success" && run.head_branch == configuration.branch {
            var artifactRequest = apiRequest(path: "/repos/\(owner)/\(name)/actions/runs/\(run.id)/artifacts?per_page=100", token: token)
            artifactRequest.httpMethod = "GET"
            let artifacts: Artifacts = try await fetch(artifactRequest)
            guard let artifact = artifacts.artifacts.first(where: {
                !$0.expired && (configuration.assetName.isEmpty || $0.name.localizedCaseInsensitiveContains(configuration.assetName))
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
        guard let baselineKey,
              let baselineIndex = history.firstIndex(where: {
                  $0.entry.key == baselineKey || legacyReleaseKey(for: $0.entry.key) == baselineKey
              }), baselineIndex > 0 else { return nil }
        let item = history[0]
        guard item.entry.key != baselineKey else { return nil }
        return GitHubUpdateCandidate(
            bundleIdentifier: app.bundleIdentifier, appName: app.name, currentVersion: app.version,
            newVersion: item.version, title: item.title, assetName: item.assetName,
            downloadURL: item.url, updateKey: item.entry.key, source: configuration.source
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

        let archive: Archive
        do { archive = try Archive(url: downloadURL, accessMode: .read) }
        catch {
            try? FileManager.default.removeItem(at: downloadURL)
            throw GitHubUpdateError.invalidArtifact
        }
        guard let ipaEntry = archive.first(where: { $0.path.lowercased().hasSuffix(".ipa") }) else {
            try? FileManager.default.removeItem(at: downloadURL)
            throw GitHubUpdateError.noIPAInArtifact
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("ipa")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
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
              url.host?.lowercased() == "github.com" else { throw GitHubUpdateError.invalidRepository }
        let pieces = url.path.split(separator: "/").map(String.init)
        guard pieces.count >= 2 else { throw GitHubUpdateError.invalidRepository }
        return (pieces[0], pieces[1].replacingOccurrences(of: ".git", with: ""))
    }

}

private final class GitHubDownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (GitHubDownloadProgress) -> Void

    init(onProgress: @escaping @Sendable (GitHubDownloadProgress) -> Void) {
        self.onProgress = onProgress
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
    case invalidRepository, invalidToken, notFound, insufficientPermissions(String?), rateLimited, unavailable, invalidResponse, downloadFailed, invalidArtifact, noIPAInArtifact
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
        case .noIPAInArtifact: "No IPA file was found in that GitHub download."
        }
    }
}
