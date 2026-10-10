import Foundation

struct GitHubUpdateTarget: Sendable {
    enum Kind: String, Sendable { case installed, liveContainer }
    let id: String
    let name: String
    let version: String
    var kind: Kind = .installed
    var observation: String? = nil
    var legacyObservation: String? = nil
}

enum GitHubBuildComparison {
    static func isNewer(_ key: String, than baseline: String, historyKeys: [String]) -> Bool {
        guard key != baseline else { return false }
        if let index = historyKeys.firstIndex(where: { $0 == baseline || legacyReleaseKey($0) == baseline }) {
            return historyKeys.first == key && index > 0
        }
        let previous = baseline.split(separator: ":")
        let latest = key.split(separator: ":")
        guard previous.count >= 3, latest.count >= 3, previous[0] == latest[0],
              let previousID = Int64(previous[1]), let latestID = Int64(latest[1]) else { return false }
        return latestID > previousID
    }

    static func legacyReleaseKey(_ key: String) -> String? {
        let parts = key.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "release" else { return nil }
        return "release:\(parts[2]):\(parts[3])"
    }
}

enum GitHubUpdateSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case latestRelease
    case actionsArtifact

    var id: String { rawValue }
    var title: String { self == .latestRelease ? "Latest release" : "Actions artifact" }
}

struct GitHubUpdateConfiguration: Codable, Identifiable, Hashable, Sendable {
    var id: String { bundleIdentifier }
    var bundleIdentifier: String
    var repositoryURL: String
    var source: GitHubUpdateSource
    var workflowFile: String
    var branch: String
    var assetName: String
    var baselineUpdateKey: String? = nil
    var lastInstalledUpdateKey: String?
    var dismissedUpdateKey: String? = nil
    var tokenID: String? = nil
    var installedBuild: GitHubInstalledBuild? = nil
    var pendingSelfUpdate: GitHubPendingSelfUpdate? = nil
    // The product ID is independent of the signing team's installed ID.
    var originalBundleIdentifier: String? = nil

    var effectiveBaselineKey: String? { lastInstalledUpdateKey ?? baselineUpdateKey }
    var sourceIdentity: String {
        let repo = GitHubSourceIdentity.repository(repositoryURL)
        let workflow = workflowFile.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ".github/workflows/", with: "")
        let branch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        return [repo, source.rawValue, source == .actionsArtifact ? workflow : "",
            source == .actionsArtifact && branch != "*" ? branch : "", assetName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()].joined(separator: "\n")
    }

    mutating func confirmInstalled(_ key: String, observation: String?) {
        // Reinstalling the same build refreshes its evidence without undoing a
        // decision to skip a different, newer build.
        if effectiveBaselineKey != key || (installedBuild != nil && installedBuild?.sourceIdentity != sourceIdentity) {
            dismissedUpdateKey = nil
        }
        pendingSelfUpdate = nil
        installedBuild = GitHubInstalledBuild(key: key, sourceIdentity: sourceIdentity, observation: observation, confirmedAt: .now)
        baselineUpdateKey = key
        lastInstalledUpdateKey = key
    }

    mutating func setInstalledBaseline(_ key: String?, observation: String? = nil) {
        pendingSelfUpdate = nil
        if key != effectiveBaselineKey { lastInstalledUpdateKey = nil; dismissedUpdateKey = nil }
        baselineUpdateKey = key
        if let key { confirmInstalled(key, observation: observation); lastInstalledUpdateKey = nil }
        else { installedBuild = nil; lastInstalledUpdateKey = nil }
    }

    func hasSameSource(as other: GitHubUpdateConfiguration) -> Bool {
        sourceIdentity == other.sourceIdentity
    }
}

struct GitHubUpdateHistoryEntry: Identifiable, Hashable, Sendable {
    let key: String
    let title: String
    let date: Date?

    var id: String { key }
}

struct GitHubUpdateCandidate: Identifiable, Equatable, Sendable {
    let bundleIdentifier: String
    let appName: String
    let currentVersion: String
    let newVersion: String
    let title: String
    let assetName: String
    let downloadURL: URL
    let updateKey: String
    let source: GitHubUpdateSource
    var repositoryURL: String? = nil
    var targetKind: GitHubUpdateTarget.Kind = .installed
    var sourceIdentity: String? = nil
    var isKnownNewer: Bool = true

    var id: String { "\(bundleIdentifier):\(updateKey)" }
}
