import Foundation

extension Notification.Name {
    static let sideKickGitHubSettingsDidChange = Notification.Name("SideKick.GitHubSettingsDidChange")
}

/// A repository IPA's GitHub source, saved when the IPA is sent to LiveContainer.
struct LiveContainerPendingSource: Codable, Equatable, Sendable {
    static let lifetime: TimeInterval = 30 * 86_400
    let bundleIdentifier: String
    let version: String
    let build: String?
    let executableIdentity: String?
    let updateKey: String?
    let configuration: GitHubUpdateConfiguration
    let createdAt: Date

    init?(_ ipa: ImportedIPA, now: Date = .now) {
        guard let origin = ipa.githubImportConfiguration, origin.sourceIdentity == ipa.githubSourceIdentity,
              !origin.repositoryURL.isEmpty else { return nil }
        bundleIdentifier = ipa.bundleIdentifier
        version = ipa.version
        build = ipa.buildVersion
        executableIdentity = ipa.executableIdentity
        updateKey = ipa.githubUpdateKey?.isEmpty == false ? ipa.githubUpdateKey : nil
        configuration = origin
        createdAt = now
    }

    var repositoryName: String {
        URL(string: configuration.repositoryURL)?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? configuration.repositoryURL
    }

    func matchesBuild(of guest: LiveContainerGuest) -> Bool {
        if let executableIdentity, let observed = guest.executableIdentity { return executableIdentity == observed }
        return guest.version == version && guest.build == (build ?? guest.build)
    }

    /// The guest runs exactly the downloaded binary, so its build can be recorded as installed.
    func verifies(_ guest: LiveContainerGuest) -> Bool {
        guard let executableIdentity, !executableIdentity.isEmpty else { return false }
        return executableIdentity == guest.executableIdentity
    }
}

actor GitHubUpdateConfigurationStore {
    static let shared = GitHubUpdateConfigurationStore()
    private static let selfUpdateOptOutKey = "sidekick.github-update.self-update-opted-out"
    private static let selfUpdateRepositoryURL = "https://github.com/huzaifah1530-bot/SideKick"
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

    /// Use published releases for SideKick itself; preserve opt-outs and custom sources.
    func ensureSelfUpdateConfiguration(for targetID: String) throws -> GitHubUpdateConfiguration? {
        guard targetID == Bundle.main.bundleIdentifier else { return nil }
        let existing = try configuration(for: targetID)
        guard existing != nil || !UserDefaults.standard.bool(forKey: Self.selfUpdateOptOutKey) else { return nil }
        let vpnExtension = Bundle.main.bundleURL.appendingPathComponent("PlugIns/SideKickVPN.appex", isDirectory: true)
        let configuration = Self.releaseDefault(for: targetID,
            includesVPN: fileManager.fileExists(atPath: vpnExtension.path), replacing: existing)
        if configuration != existing { try save(configuration) }
        return configuration
    }

    static func releaseDefault(for targetID: String, includesVPN: Bool,
                               replacing existing: GitHubUpdateConfiguration? = nil) -> GitHubUpdateConfiguration {
        if let existing {
            guard GitHubSourceIdentity.repository(existing.repositoryURL) == GitHubSourceIdentity.repository(selfUpdateRepositoryURL) else { return existing }
            switch existing.source {
            case .actionsArtifact:
                guard existing.selfUpdateReleaseMigrationApplied != true,
                      existing.workflowFile == "ios-build.yml", existing.branch == "main",
                      ["SideKick-unsigned-ipa", "SideKick-vpn-unsigned-ipa"].contains(existing.assetName) else { return existing }
            case .latestRelease:
                guard ["SideKick-unsigned.ipa", "SideKick-vpn-unsigned.ipa"].contains(existing.assetName) else { return existing }
            }
        }

        // Actions receipts and skipped keys cannot establish an installed release.
        let configuration = GitHubUpdateConfiguration(
            bundleIdentifier: targetID,
            repositoryURL: Self.selfUpdateRepositoryURL,
            source: .latestRelease,
            workflowFile: "",
            branch: "",
            assetName: includesVPN ? "SideKick+Vpn.read.release.description.ipa" : "SideKick.ipa",
            baselineUpdateKey: nil,
            lastInstalledUpdateKey: nil,
            tokenID: existing?.tokenID,
            originalBundleIdentifier: existing?.originalBundleIdentifier,
            selfUpdateReleaseMigrationApplied: true
        )
        return configuration
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

    // Called only after the user confirms this downloaded build was imported.
    // Sharing an IPA does not provide an installation receipt from LiveContainer.
    @discardableResult
    func recordLiveContainerImport(_ ipa: ImportedIPA, guest: LiveContainerGuest,
                                   connection: LiveContainerConnection) throws -> Bool {
        guard LiveContainerImportPolicy.matches(ipa, guest: guest, connection: connection) else {
            throw LiveContainerImportError.guestMismatch
        }
        guard let origin = ipa.githubImportConfiguration,
              origin.sourceIdentity == ipa.githubSourceIdentity,
              !origin.repositoryURL.isEmpty, !origin.assetName.isEmpty else {
            throw LiveContainerImportError.missingSource
        }
        if let key = ipa.githubUpdateKey, !key.isEmpty {
            return try recordSuccessfulImport(origin, key: key, for: guest.updateTarget)
        }
        return try attachLiveContainerSource(origin, guest: guest)
    }

    // MARK: Repository imports handed to LiveContainer

    private var pendingSourcesURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("livecontainer-pending-sources.json")
    }

    func pendingLiveContainerSources() throws -> [LiveContainerPendingSource] {
        guard fileManager.fileExists(atPath: pendingSourcesURL.path) else { return [] }
        let values = try JSONDecoder().decode([LiveContainerPendingSource].self, from: Data(contentsOf: pendingSourcesURL))
        return values.filter { $0.createdAt > Date.now.addingTimeInterval(-LiveContainerPendingSource.lifetime) }
    }

    private func persistPendingSources(_ values: [LiveContainerPendingSource]) throws {
        try fileManager.createDirectory(at: pendingSourcesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(values).write(to: pendingSourcesURL, options: .atomic)
    }

    /// Remembers a repository IPA's GitHub source when it's sent to LiveContainer. This is kept
    /// apart from the IPA itself, so the source still attaches if the IPA is deleted, or if
    /// LiveContainer's folder is linked only later.
    func rememberLiveContainerHandoff(_ ipa: ImportedIPA) throws {
        guard let source = LiveContainerPendingSource(ipa) else { return }
        var values = try pendingLiveContainerSources().filter {
            $0.bundleIdentifier.caseInsensitiveCompare(source.bundleIdentifier) != .orderedSame
        }
        values.append(source)
        try persistPendingSources(values)
    }

    /// The pending repository source for a guest without its own, if one was sent for this app.
    func pendingLiveContainerSource(for guest: LiveContainerGuest) throws -> LiveContainerPendingSource? {
        guard try configuration(for: guest.id) == nil else { return nil }
        return try pendingLiveContainerSources().first {
            $0.bundleIdentifier.caseInsensitiveCompare(guest.bundleIdentifier) == .orderedSame
        }
    }

    /// Attaches a remembered source to the guest the user picked. Records the installed build only
    /// when the guest's binary is provably the downloaded one.
    @discardableResult
    func attachPendingLiveContainerSource(to guest: LiveContainerGuest) throws -> Bool {
        guard let pending = try pendingLiveContainerSource(for: guest) else { return false }
        try apply(pending, to: guest)
        try persistPendingSources(try pendingLiveContainerSources().filter { $0 != pending })
        return true
    }

    private func apply(_ pending: LiveContainerPendingSource, to guest: LiveContainerGuest) throws {
        if let key = pending.updateKey, pending.verifies(guest) {
            _ = try recordSuccessfulImport(pending.configuration, key: key, for: guest.updateTarget)
        } else {
            _ = try attachLiveContainerSource(pending.configuration, guest: guest)
        }
    }

    /// Links remembered sources to the guest LiveContainer created. Never guesses between two
    /// copies: with several candidates, an exact build match is required, otherwise the guest
    /// page offers the source to the user.
    private func reconcilePendingSources(catalogue: LiveContainerState) throws {
        var pending = try pendingLiveContainerSources()
        guard !pending.isEmpty else { return }
        let forgetting = Set(catalogue.pendingForgetGuestIDs.values.flatMap { $0 })
        let eligible = try catalogue.apps.filter { guest in
            guard !forgetting.contains(guest.id), guest.isAvailable, guest.warning == nil,
                  let connection = catalogue.connections.first(where: { $0.id == guest.connectionID }),
                  connection.isConnected, connection.error == nil, connection.storageKind != .snapshot else { return false }
            return try configuration(for: guest.id) == nil
        }
        var changed = false
        for source in pending {
            let sameApp = eligible.filter { $0.bundleIdentifier.caseInsensitiveCompare(source.bundleIdentifier) == .orderedSame }
            let exact = sameApp.filter { source.matchesBuild(of: $0) }
            guard let guest = sameApp.count == 1 ? sameApp.first : (exact.count == 1 ? exact.first : nil) else { continue }
            try apply(source, to: guest)
            pending.removeAll { $0 == source }
            changed = true
        }
        if changed { try persistPendingSources(pending) }
    }

    private func attachLiveContainerSource(_ origin: GitHubUpdateConfiguration, guest: LiveContainerGuest) throws -> Bool {
        if let existing = try configuration(for: guest.id) { return existing.hasSameSource(as: origin) }
        var source = origin
        source.bundleIdentifier = guest.id
        source.baselineUpdateKey = nil
        source.lastInstalledUpdateKey = nil
        source.installedBuild = nil
        source.pendingSelfUpdate = nil
        source.clearDismissedUpdate()
        try save(source)
        return true
    }

    @discardableResult
    func reconcileLiveContainerImports(_ imports: [ImportedIPA], catalogue: LiveContainerState) throws -> [ImportedIPA] {
        let pending = imports.filter { $0.liveContainerHandoffRequested == true && $0.githubImportConfiguration != nil }
        var linked: [ImportedIPA] = []
        for guest in catalogue.apps {
            guard !catalogue.pendingForgetGuestIDs.values.flatMap({ $0 }).contains(guest.id),
                  guest.warning == nil,
                  let connection = catalogue.connections.first(where: { $0.id == guest.connectionID }) else { continue }
            let matching = pending.filter { ipa in
                guard LiveContainerImportPolicy.matches(ipa, guest: guest, connection: connection) else { return false }
                // Never silently choose between installations or different repository builds.
                return catalogue.apps.filter { other in
                    guard let owner = catalogue.connections.first(where: { $0.id == other.connectionID }) else { return false }
                    return LiveContainerImportPolicy.matches(ipa, guest: other, connection: owner)
                }.count == 1
            }
            guard let ipa = matching.first, let origin = ipa.githubImportConfiguration,
                  origin.sourceIdentity == ipa.githubSourceIdentity,
                  Set(matching.compactMap(\.githubSourceIdentity)).count == 1,
                  Set(matching.map { $0.githubUpdateKey ?? "" }).count == 1 else { continue }
            let existing = try configuration(for: guest.id)
            guard existing == nil || existing?.hasSameSource(as: origin) == true else { continue }
            if let key = ipa.githubUpdateKey, !key.isEmpty, LiveContainerImportPolicy.verifiesBuild(ipa, guest: guest) {
                if existing?.installedBuild?.key != key || existing?.installedBuild?.observation != guest.updateTarget.observation {
                    _ = try recordSuccessfulImport(origin, key: key, for: guest.updateTarget)
                }
            } else if existing == nil {
                // Repository tracking is known even when LiveContainer changes the binary.
                // Preserve it without inventing an installed-build receipt from version labels.
                _ = try attachLiveContainerSource(origin, guest: guest)
            }
            linked.append(contentsOf: matching)
        }
        try reconcilePendingSources(catalogue: catalogue)
        return linked
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
            result.clearDismissedUpdate()
        }
        if baselineWasEdited { result.setInstalledBaseline(baselineKey, observation: observation) }
        if settings.bundleIdentifier == Bundle.main.bundleIdentifier {
            result.selfUpdateReleaseMigrationApplied = true
        }
        try save(result)
        if settings.bundleIdentifier == Bundle.main.bundleIdentifier {
            UserDefaults.standard.removeObject(forKey: Self.selfUpdateOptOutKey)
        }
    }

    @discardableResult
    func skip(key: String, title: String, date: Date?, targetID: String, expectedSource: String) throws -> Bool {
        guard var current = try configuration(for: targetID), current.sourceIdentity == expectedSource else { return false }
        current.dismissedUpdateKey = key
        current.dismissedUpdateTitle = title
        current.dismissedUpdateDate = date
        try save(current)
        return true
    }

    /// Clears a skipped build only while the same source and skipped key remain current.
    @discardableResult
    func undoSkip(key: String, targetID: String, expectedSource: String) throws -> Bool {
        guard var current = try configuration(for: targetID),
              current.sourceIdentity == expectedSource,
              current.dismissedUpdateKey == key else { return false }
        current.clearDismissedUpdate()
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
        if bundleIdentifier == Bundle.main.bundleIdentifier {
            UserDefaults.standard.set(true, forKey: Self.selfUpdateOptOutKey)
        }
    }

    private func persist(_ values: [GitHubUpdateConfiguration]) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(values).write(to: fileURL, options: .atomic)
        NotificationCenter.default.post(name: .sideKickGitHubSettingsDidChange, object: nil)
    }
}
