import Foundation

extension Notification.Name {
    static let sideKickGitHubSettingsDidChange = Notification.Name("SideKick.GitHubSettingsDidChange")
}

actor GitHubUpdateConfigurationStore {
    static let shared = GitHubUpdateConfigurationStore()
    private let fileManager = FileManager.default
    private let fileURL: URL
    private let legacyFileURLs: [URL]

    init(fileURL: URL? = nil, legacyFileURLs: [URL]? = nil) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let relativePath = "GitHubUpdates/apps.json"
        self.fileURL = fileURL ?? support.appendingPathComponent("SideKick", isDirectory: true).appendingPathComponent(relativePath)
        if let legacyFileURLs {
            self.legacyFileURLs = legacyFileURLs
        } else if fileURL != nil {
            self.legacyFileURLs = []
        } else {
            var locations = [support.appendingPathComponent(relativePath)]
            #if canImport(UIKit)
            if let group = Bundle.main.altstoreAppGroup,
               let shared = fileManager.containerURL(forSecurityApplicationGroupIdentifier: group) {
                locations += [shared.appendingPathComponent(relativePath),
                    shared.appendingPathComponent("SideKick", isDirectory: true).appendingPathComponent(relativePath)]
            }
            #endif
            self.legacyFileURLs = locations
        }
    }

    func all() throws -> [GitHubUpdateConfiguration] {
        if fileManager.fileExists(atPath: fileURL.path) {
            return try JSONDecoder().decode([GitHubUpdateConfiguration].self, from: Data(contentsOf: fileURL))
        }
        // Import once. A valid empty current file is authoritative, so removed
        // sources cannot reappear from an old copy on the next launch.
        var values: [GitHubUpdateConfiguration] = []
        var foundLegacyFile = false
        for legacy in legacyFileURLs where legacy != fileURL && fileManager.fileExists(atPath: legacy.path) {
            let old = try JSONDecoder().decode([GitHubUpdateConfiguration].self, from: Data(contentsOf: legacy))
            foundLegacyFile = true
            // Private legacy data wins over App Group copies. Never blend a
            // receipt or skipped key from a different source into a record.
            for value in old where !values.contains(where: { $0.id == value.id }) { values.append(value) }
        }
        if foundLegacyFile { try persist(values) }
        return values
    }

    func configuration(for bundleIdentifier: String) throws -> GitHubUpdateConfiguration? {
        try all().first { $0.bundleIdentifier == bundleIdentifier }
    }

    func save(_ configuration: GitHubUpdateConfiguration) throws {
        var values = try all().filter { $0.bundleIdentifier != configuration.bundleIdentifier }
        values.append(configuration)
        try persist(values)
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

    // Move only an unambiguous obsolete ID. Keep conflicts intact for explicit
    // resolution; a destination's existence is never permission to delete data.
    func migrateInstalledIdentifiers(_ installations: [String: [String]]) throws {
        var values = try all()
        let before = values
        let activeIDs = Set(installations.values.flatMap { $0 })
        for (original, copies) in installations {
            let identities = Set(copies)
            for index in values.indices where identities.contains(values[index].id) {
                values[index].originalBundleIdentifier = original
            }
            guard identities.count == 1, let identity = identities.first,
                  !values.contains(where: { $0.id == identity }) else { continue }
            let candidates = values.indices.filter { index in
                let value = values[index]
                guard !activeIDs.contains(value.id), !value.id.hasPrefix("livecontainer:") else { return false }
                if let product = value.originalBundleIdentifier { return product == original }
                if value.id == original { return true }
                // Older signed records predate the explicit product ID. Only
                // accept Apple's ten-character team suffix, never an arbitrary
                // bundle ID with a shared prefix.
                guard value.id.hasPrefix(original + ".") else { return false }
                let suffix = value.id.dropFirst(original.count + 1)
                return suffix.count == 10 && suffix.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
            }
            guard candidates.count == 1, let index = candidates.first else { continue }
            let oldID = values[index].id
            values[index].bundleIdentifier = identity
            values[index].originalBundleIdentifier = original
            let prefix = "sidekick.github-update."
            let oldHistory = prefix + oldID + ".last-notified"
            let newHistory = prefix + identity + ".last-notified"
            if UserDefaults.standard.string(forKey: newHistory) == nil,
               let key = UserDefaults.standard.string(forKey: oldHistory) {
                UserDefaults.standard.set(key, forKey: newHistory)
            }
        }
        if values != before { try persist(values) }
    }

    func migrateInstalledObservations(_ targets: [GitHubUpdateTarget]) throws {
        var values = try all()
        let before = values
        for target in targets {
            guard let index = values.firstIndex(where: { $0.id == target.id }),
                  let receipt = values[index].installedBuild,
                  receipt.sourceIdentity == values[index].sourceIdentity,
                  let legacy = target.legacyObservation, receipt.observation == legacy,
                  let observation = target.observation, observation != legacy,
                  !legacy.hasSuffix("|no-content-fingerprint") else { continue }
            // Upgrade evidence only while the original observation still matches.
            // Do not reconfirm an externally replaced IPA from its version label.
            values[index].installedBuild = GitHubInstalledBuild(key: receipt.key,
                sourceIdentity: receipt.sourceIdentity, observation: observation, confirmedAt: receipt.confirmedAt)
        }
        if values != before { try persist(values) }
    }

    func remove(bundleIdentifier: String) throws {
        let values = try all().filter { $0.bundleIdentifier != bundleIdentifier }
        try persist(values)
    }

    private func persist(_ values: [GitHubUpdateConfiguration]) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(values).write(to: fileURL, options: .atomic)
        NotificationCenter.default.post(name: .sideKickGitHubSettingsDidChange, object: nil)
    }
}
