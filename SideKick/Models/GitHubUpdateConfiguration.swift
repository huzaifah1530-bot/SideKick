import Foundation

enum GitHubUpdateSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case latestRelease
    case actionsArtifact

    var id: String { rawValue }
    var title: String { self == .latestRelease ? "Latest release" : "Actions artifact" }
}

struct GitHubUpdateConfiguration: Codable, Identifiable, Equatable, Sendable {
    var id: String { bundleIdentifier }
    let bundleIdentifier: String
    var repositoryURL: String
    var source: GitHubUpdateSource
    var workflowFile: String
    var branch: String
    var assetName: String
    var baselineUpdateKey: String? = nil
    var lastInstalledUpdateKey: String?
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

    var id: String { "\(bundleIdentifier):\(updateKey)" }
}
