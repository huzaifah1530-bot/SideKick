import Foundation
import ZIPFoundation

actor GitHubUpdateService {
    private struct GitHubUser: Decodable { let login: String }
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

    private let historyClient = GitHubHistoryClient()

    func importChoices(repositoryURL: String, source: GitHubUpdateSource, workflow: String, branch: String, token: String?, page: Int) async throws -> GitHubImportPage {
        let configuration = GitHubUpdateConfiguration(bundleIdentifier: "", repositoryURL: repositoryURL,
            source: source, workflowFile: workflow, branch: branch, assetName: "", lastInstalledUpdateKey: nil)
        let result = try await historyClient.page(configuration: configuration, token: token, page: page, allowMultiple: true)
        return GitHubImportPage(choices: result.builds.map { build in
            GitHubImportChoice(candidate: GitHubUpdateCandidate(bundleIdentifier: "", appName: build.title,
                currentVersion: "", newVersion: build.version, title: build.title, assetName: build.assetName,
                downloadURL: build.downloadURL, updateKey: build.key, source: source,
                repositoryURL: GitHubSourceIdentity.repository(repositoryURL)), workflow: workflow, branch: branch, date: build.date)
        }, hasMore: result.hasMore)
    }

    func check(for target: GitHubUpdateTarget, configuration: GitHubUpdateConfiguration, token: String? = nil) async throws -> GitHubCheckResult {
        var history: [GitHubTrackedBuild] = []
        var missingNewerDownload = false
        for page in 1...5 {
            try Task.checkCancellation()
            let result = try await historyClient.page(configuration: configuration, token: token, page: page, latestOnly: true)
            history += result.builds
            missingNewerDownload = missingNewerDownload || result.newerBuildHasNoDownload
            if !history.isEmpty || !result.hasMore { break }
        }
        let result = GitHubTrackingPolicy.check(target: target, configuration: configuration, history: history)
        if result.state == .current && missingNewerDownload {
            return GitHubCheckResult(targetID: target.id, state: .noMatchingDownload,
                detail: "A more recent successful build has no matching downloadable file yet.")
        }
        return result
    }

    func candidate(for target: GitHubUpdateTarget, configuration: GitHubUpdateConfiguration, token: String? = nil) async throws -> GitHubUpdateCandidate? {
        try await check(for: target, configuration: configuration, token: token).candidate
    }

    func history(for configuration: GitHubUpdateConfiguration, token: String? = nil, page: Int = 1) async throws -> [GitHubUpdateHistoryEntry] {
        try await historyClient.page(configuration: configuration, token: token, page: page).builds.map(\.historyEntry)
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
        let (downloadURL, response) = try await ProgressFileDownload(onProgress: onProgress).download(request)
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
            baselineUpdateKey: nil, lastInstalledUpdateKey: nil,
            tokenID: tokenID)
    }
}
