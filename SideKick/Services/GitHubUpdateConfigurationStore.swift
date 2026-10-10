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
