import Foundation
import ZIPFoundation

actor GitHubUpdateService {
    private struct GitHubUser: Decodable { let login: String }
    private struct Release: Decodable {
        let tag_name: String
        let name: String?
        let assets: [ReleaseAsset]
    }
    private struct ReleaseAsset: Decodable {
        let name: String
        let url: URL
    }
    private struct WorkflowRuns: Decodable { let workflow_runs: [WorkflowRun] }
    private struct WorkflowRun: Decodable {
        let id: Int
        let name: String?
        let display_title: String?
        let head_branch: String
        let conclusion: String?
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
            var request = apiRequest(path: "/repos/\(repository.owner)/\(repository.name)/releases/latest", token: token)
            request.httpMethod = "GET"
            let release: Release = try await fetch(request)
            guard let asset = release.assets
                .filter({ $0.name.lowercased().hasSuffix(".ipa") })
                .first(where: { configuration.assetName.isEmpty || $0.name.localizedCaseInsensitiveContains(configuration.assetName) })
            else { return nil }
            guard isNewer(release.tag_name, than: app.version) else { return nil }
            let key = "release:\(release.tag_name):\(asset.name)"
            guard configuration.lastInstalledUpdateKey != key else { return nil }
            return GitHubUpdateCandidate(
                bundleIdentifier: app.bundleIdentifier, appName: app.name, currentVersion: app.version,
                newVersion: release.tag_name, title: release.name ?? release.tag_name, assetName: asset.name,
                downloadURL: asset.url, updateKey: key, source: .latestRelease
            )
        case .actionsArtifact:
            var request = apiRequest(path: "/repos/\(repository.owner)/\(repository.name)/actions/workflows/\(configuration.workflowFile)/runs?branch=\(configuration.branch.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? configuration.branch)&status=success&per_page=10", token: token)
            request.httpMethod = "GET"
            let runs: WorkflowRuns = try await fetch(request)
            guard let run = runs.workflow_runs.first(where: { $0.conclusion == "success" && $0.head_branch == configuration.branch }) else { return nil }
            var artifactRequest = apiRequest(path: "/repos/\(repository.owner)/\(repository.name)/actions/runs/\(run.id)/artifacts?per_page=100", token: token)
            artifactRequest.httpMethod = "GET"
            let artifacts: Artifacts = try await fetch(artifactRequest)
            guard let artifact = artifacts.artifacts.first(where: {
                !$0.expired && (configuration.assetName.isEmpty || $0.name.localizedCaseInsensitiveContains(configuration.assetName))
            }) else { return nil }
            let key = "actions:\(run.id):\(artifact.id)"
            guard configuration.lastInstalledUpdateKey != key else { return nil }
            return GitHubUpdateCandidate(
                bundleIdentifier: app.bundleIdentifier, appName: app.name, currentVersion: app.version,
                newVersion: run.display_title ?? "Build \(run.id)",
                title: run.name ?? run.display_title ?? "Successful GitHub Actions build",
                assetName: artifact.name, downloadURL: artifact.archive_download_url,
                updateKey: key, source: .actionsArtifact
            )
        }
    }

    func validateToken(_ token: String) async throws -> String {
        let request = apiRequest(path: "/user", token: token)
        let user: GitHubUser = try await fetch(request)
        return user.login
    }

    func downloadIPA(
        for candidate: GitHubUpdateCandidate,
        token: String? = nil,
        onProgress: @escaping @Sendable (Double?) -> Void = { _ in }
    ) async throws -> URL {
        var request = URLRequest(url: candidate.downloadURL)
        request.setValue(candidate.source == .latestRelease ? "application/octet-stream" : "application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SideKick iOS app", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let delegate = GitHubDownloadProgressDelegate(onProgress: onProgress)
        let (downloadURL, response) = try await URLSession.shared.download(for: request, delegate: delegate)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            try? FileManager.default.removeItem(at: downloadURL)
            throw GitHubUpdateError.downloadFailed
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
            if response.statusCode == 401 { throw GitHubUpdateError.invalidToken }
            if response.statusCode == 404 { throw GitHubUpdateError.notFound }
            if response.statusCode == 403 { throw GitHubUpdateError.rateLimited }
            throw GitHubUpdateError.unavailable
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw GitHubUpdateError.invalidResponse }
    }

    private func parseRepository(_ value: String) throws -> (owner: String, name: String) {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.host?.lowercased() == "github.com" else { throw GitHubUpdateError.invalidRepository }
        let pieces = url.path.split(separator: "/").map(String.init)
        guard pieces.count >= 2 else { throw GitHubUpdateError.invalidRepository }
        return (pieces[0], pieces[1].replacingOccurrences(of: ".git", with: ""))
    }

    private func isNewer(_ candidate: String, than installed: String) -> Bool {
        let lhs = candidate.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        let rhs = installed.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard !lhs.isEmpty, !rhs.isEmpty else { return candidate != installed }
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a > b }
        }
        return false
    }
}

private final class GitHubDownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double?) -> Void

    init(onProgress: @escaping @Sendable (Double?) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let progress = totalBytesExpectedToWrite > 0
            ? min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
            : nil
        onProgress(progress)
    }
}

enum GitHubUpdateError: LocalizedError {
    case invalidRepository, invalidToken, notFound, rateLimited, unavailable, invalidResponse, downloadFailed, invalidArtifact, noIPAInArtifact
    var errorDescription: String? {
        switch self {
        case .invalidRepository: "Enter a public GitHub repository URL, such as https://github.com/owner/repository."
        case .invalidToken: "GitHub rejected this token. Check that it’s valid and has the required read-only repository and Actions access."
        case .notFound: "GitHub could not find that public repository, release, workflow, or artifact. Check the app’s GitHub settings."
        case .rateLimited: "GitHub temporarily limited update checks. Try again later."
        case .unavailable: "GitHub is temporarily unavailable or the repository is private."
        case .invalidResponse: "GitHub returned update information SideKick couldn’t read."
        case .downloadFailed: "SideKick couldn’t download the GitHub update."
        case .invalidArtifact: "The GitHub Actions artifact is damaged or isn’t a valid ZIP archive."
        case .noIPAInArtifact: "No IPA file was found in that GitHub download."
        }
    }
}
