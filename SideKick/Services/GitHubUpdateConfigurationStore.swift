import Foundation

extension Notification.Name {
    static let sideKickGitHubSettingsDidChange = Notification.Name("SideKick.GitHubSettingsDidChange")
}

actor GitHubUpdateConfigurationStore {
    static let shared = GitHubUpdateConfigurationStore()
    private let fileManager = FileManager.default
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.fileURL = fileURL ?? support.appendingPathComponent("GitHubUpdates", isDirectory: true).appendingPathComponent("apps.json")
    }

    func all() throws -> [GitHubUpdateConfiguration] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([GitHubUpdateConfiguration].self, from: Data(contentsOf: fileURL))
    }

    func configuration(for bundleIdentifier: String) throws -> GitHubUpdateConfiguration? {
        try all().first { $0.bundleIdentifier == bundleIdentifier }
    }

    func save(_ configuration: GitHubUpdateConfiguration) throws {
        var values = try all().filter { $0.bundleIdentifier != configuration.bundleIdentifier }
        values.append(configuration)
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(values).write(to: fileURL, options: .atomic)
        NotificationCenter.default.post(name: .sideKickGitHubSettingsDidChange, object: nil)
    }


    func prepareSelfUpdate(key: String, targetID: String, expectedSource: String, executableIdentity: String) throws {
        guard var current = try configuration(for: targetID), current.sourceIdentity == expectedSource else { return }
        current.pendingSelfUpdate = GitHubPendingSelfUpdate(key: key, sourceIdentity: expectedSource, executableIdentity: executableIdentity)
        try save(current)
    }

    @discardableResult
    func recoverSelfUpdate(for target: GitHubUpdateTarget, executableIdentity: String) throws -> Bool {
        guard var current = try configuration(for: target.id), let pending = current.pendingSelfUpdate,
              pending.sourceIdentity == current.sourceIdentity, pending.executableIdentity == executableIdentity else { return false }
        current.confirmInstalled(pending.key, observation: target.observation)
        try save(current)
        return true
    }

    func cancelSelfUpdate(targetID: String, key: String) throws {
        guard var current = try configuration(for: targetID), current.pendingSelfUpdate?.key == key else { return }
        current.pendingSelfUpdate = nil
        try save(current)
    }

    @discardableResult
    func recordInstalled(key: String, for target: GitHubUpdateTarget, expectedSource: String) throws -> Bool {
        guard var current = try configuration(for: target.id), current.sourceIdentity == expectedSource else { return false }
        current.confirmInstalled(key, observation: target.observation)
        try save(current)
        return true
    }

    @discardableResult
    func recordSuccessfulImport(_ origin: GitHubUpdateConfiguration, key: String, for target: GitHubUpdateTarget) throws -> Bool {
        var result: GitHubUpdateConfiguration
        if let current = try configuration(for: target.id) {
            guard current.hasSameSource(as: origin) else { return false }
            result = current
        } else {
            result = origin
            result.bundleIdentifier = target.id
        }
        result.confirmInstalled(key, observation: target.observation)
        try save(result)
        return true
    }

    func saveSettings(_ settings: GitHubUpdateConfiguration, baselineKey: String?, baselineWasEdited: Bool, observation: String?) throws {
        var result = settings
        if let current = try configuration(for: settings.id), current.hasSameSource(as: settings) {
            result = current
            result.repositoryURL = settings.repositoryURL
            result.source = settings.source
            result.workflowFile = settings.workflowFile
            result.branch = settings.branch
            result.assetName = settings.assetName
            result.tokenID = settings.tokenID
        } else {
            result.pendingSelfUpdate = nil
            result.installedBuild = nil
            result.lastInstalledUpdateKey = nil
            result.baselineUpdateKey = nil
            result.dismissedUpdateKey = nil
        }
        if baselineWasEdited { result.setInstalledBaseline(baselineKey, observation: observation) }
        try save(result)
    }

    @discardableResult
    func skip(key: String, targetID: String, expectedSource: String) throws -> Bool {
        guard var current = try configuration(for: targetID), current.sourceIdentity == expectedSource else { return false }
        current.dismissedUpdateKey = key
        try save(current)
        return true
    }

    // Old versions keyed sources by the IPA's original ID. Move them only when
    // there is one installed copy, keeping every saved baseline and token intact.
    func migrateInstalledIdentifiers(_ installations: [String: [String]]) throws {
        for (original, copies) in installations {
            let identities = Set(copies)
            guard identities.count == 1, let identity = identities.first, identity != original,
                  var old = try configuration(for: original) else { continue }
            if try configuration(for: identity) == nil {
                old.bundleIdentifier = identity
                try save(old)
            }
            let prefix = "sidekick.github-update."
            let oldHistory = prefix + original + ".last-notified"
            let newHistory = prefix + identity + ".last-notified"
            if UserDefaults.standard.string(forKey: newHistory) == nil,
               let key = UserDefaults.standard.string(forKey: oldHistory) {
                UserDefaults.standard.set(key, forKey: newHistory)
            }
            try remove(bundleIdentifier: original)
        }
    }

    func remove(bundleIdentifier: String) throws {
        let values = try all().filter { $0.bundleIdentifier != bundleIdentifier }
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(values).write(to: fileURL, options: .atomic)
        NotificationCenter.default.post(name: .sideKickGitHubSettingsDidChange, object: nil)
    }
}
