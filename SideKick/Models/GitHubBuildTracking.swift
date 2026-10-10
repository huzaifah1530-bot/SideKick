import Foundation

struct GitHubInstalledBuild: Codable, Hashable, Sendable {
    let key: String
    let sourceIdentity: String
    let observation: String?
    let confirmedAt: Date
}

enum GitHubSourceIdentity {
    static func repository(_ value: String) -> String {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else { return value }
        let parts = url.path.split(separator: "/").prefix(2).map(String.init)
        guard parts.count == 2 else { return value }
        let name = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        return "https://github.com/" + parts[0].lowercased() + "/" + name.lowercased()
    }
}

struct GitHubTrackedBuild: Sendable {
    let key: String
    let title: String
    let version: String
    let assetName: String
    let downloadURL: URL
    let date: Date?
    var historyEntry: GitHubUpdateHistoryEntry { GitHubUpdateHistoryEntry(key: key, title: title, date: date) }
}

enum GitHubCheckState: String, Sendable {
    case notConfigured, unknownInstalledBuild, current, updateAvailable, skipped, noMatchingDownload, installedAhead, indeterminate, failed
    var needsAttention: Bool { [.unknownInstalledBuild, .noMatchingDownload, .indeterminate, .failed].contains(self) }
    var message: String {
        switch self {
        case .notConfigured: "Configure a GitHub source to track this app."
        case .unknownInstalledBuild: "Confirm the installed GitHub build. SideKick cannot verify it from the version label alone."
        case .current: "The confirmed installed build matches the latest downloadable build."
        case .updateAvailable: "A newer downloadable build is available."
        case .skipped: "The latest build was skipped. The installed build has not changed."
        case .noMatchingDownload: "No matching downloadable build was found. Check the asset, workflow, branch, and artifact expiry."
        case .installedAhead: "The confirmed installed build is ahead of the latest downloadable build."
        case .indeterminate: "The available file differs, but its order cannot be verified. Review the build or confirm your installed version."
        case .failed: "The update check failed. The installed build has not changed."
        }
    }
}

struct GitHubCheckResult: Sendable {
    let targetID: String
    let state: GitHubCheckState
    var candidate: GitHubUpdateCandidate? = nil
    var detail: String? = nil
}

enum GitHubTrackingPolicy {
    enum Comparison: Equatable { case same, newer, older, unknown }

    static func compare(_ latest: String, to installed: String) -> Comparison {
        if latest == installed { return .same }
        let a = latest.split(separator: ":", omittingEmptySubsequences: false)
        let b = installed.split(separator: ":", omittingEmptySubsequences: false)
        guard a.count == b.count, a.first == b.first else { return .unknown }
        let positions: [Int]
        if a.first == "actions-v2", a.count == 6 { positions = [2, 3, 4] }
        else if a.first == "release-v2", a.count == 4 {
            guard a[1] == b[1] else { return .unknown }
            positions = [2]
        }
        else { return .unknown }
        for position in positions {
            guard let x = Int64(a[position]), let y = Int64(b[position]) else { return .unknown }
            if x != y { return x > y ? .newer : .older }
        }
        // A changed digest/revision of the same ID is different, not proven installed.
        return .unknown
    }

    static func check(target: GitHubUpdateTarget, configuration: GitHubUpdateConfiguration, history: [GitHubTrackedBuild]) -> GitHubCheckResult {
        guard let latest = history.first else { return GitHubCheckResult(targetID: target.id, state: .noMatchingDownload) }
        let receipt = configuration.installedBuild
        let trusted = receipt?.sourceIdentity == configuration.sourceIdentity && receipt?.observation == target.observation
        let state: GitHubCheckState
        if !trusted || receipt == nil { state = .unknownInstalledBuild }
        else {
            let relation = compare(latest.key, to: receipt!.key)
            if relation == .same { return GitHubCheckResult(targetID: target.id, state: .current) }
            if relation == .older { return GitHubCheckResult(targetID: target.id, state: .installedAhead) }
            state = relation == .newer ? .updateAvailable : .indeterminate
        }
        if latest.key == configuration.dismissedUpdateKey { return GitHubCheckResult(targetID: target.id, state: .skipped) }
        let candidate = GitHubUpdateCandidate(bundleIdentifier: target.id, appName: target.name, currentVersion: target.version,
            newVersion: latest.version, title: latest.title, assetName: latest.assetName, downloadURL: latest.downloadURL,
            updateKey: latest.key, source: configuration.source, repositoryURL: configuration.repositoryURL,
            targetKind: target.kind, sourceIdentity: configuration.sourceIdentity, isKnownNewer: state == .updateAvailable)
        return GitHubCheckResult(targetID: target.id, state: state, candidate: candidate)
    }
}

struct GitHubPendingSelfUpdate: Codable, Hashable, Sendable {
    let key: String
    let sourceIdentity: String
    let executableIdentity: String
}

// LC_UUID identifies a linked binary and survives re-signing. Unsupported or
// malformed binaries remain unverified rather than falling back to a version label.
enum GitHubExecutableIdentity {
    static func read(_ data: Data) -> String? {
        let bytes = Array(data)
        guard bytes.count >= 32, Array(bytes.prefix(4)) == [0xcf, 0xfa, 0xed, 0xfe] else { return nil }
        func word(_ offset: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
        }
        let count = Int(word(16)), size = Int(word(20))
        guard size <= bytes.count - 32, count <= size / 8 else { return nil }
        let end = 32 + size
        var offset = 32
        for _ in 0..<count {
            guard offset <= end - 8 else { return nil }
            let command = word(offset), length = Int(word(offset + 4))
            guard length >= 8, length <= end - offset else { return nil }
            if command == 0x1b {
                guard length == 24 else { return nil }
                return bytes[(offset + 8)..<(offset + 24)].map { String(format: "%02x", $0) }.joined()
            }
            offset += length
        }
        return nil
    }
}
