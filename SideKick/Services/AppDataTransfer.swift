import Foundation

struct AppDataTransferIdentity: Codable, Equatable {
    let schema: Int
    let bundleIdentifier: String
    let version: String
    let build: String
    var appGroupIdentifiers: [String]? = nil
    var appGroupPreferences: [String: [String]]? = nil
    var appGroupMainPreferences: [String]? = nil
}

enum AppDataTransferError: LocalizedError {
    case invalidFolder, identityMismatch, unsafeFile, changedDuringCopy, appGroupUnavailable, preferenceConflict
    var errorDescription: String? {
        switch self {
        case .invalidFolder: "Choose the exported SideKick data folder containing Documents, Library and SideKickTransfer.json."
        case .identityMismatch: "This data belongs to another app or app version. Restore using the original signing identity and matching version."
        case .unsafeFile: "The transfer contains a link or unsupported file. No native data was replaced."
        case .changedDuringCopy: "Files changed while being copied. Close the guest completely and try again."
        case .appGroupUnavailable: "The app’s shared data could not be accessed or does not match this backup. Keep the native app and check its App Group signing permissions."
        case .preferenceConflict: "The app and its App Groups contain conflicting shared settings. The export was stopped so no settings are silently overwritten. Keep the native app installed."
        }
    }
}

/// Shared by SideKick and the native sandbox helper. LiveContainer owns guest
/// registration; this engine transfers files only, never Keychain credentials.
enum AppDataTransfer {
    static let marker = "SideKickTransfer.json"
    private static let directories = ["Documents", "Library"]

    static func readIdentity(at root: URL) throws -> AppDataTransferIdentity {
        try validateTreeRoot(root)
        let file = root.appendingPathComponent(marker)
        try validateNode(file)
        guard (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max < 65_536 else {
            throw AppDataTransferError.invalidFolder
        }
        let value = try JSONDecoder().decode(AppDataTransferIdentity.self, from: Data(contentsOf: file))
        guard value.schema == 1 || value.schema == 2 else { throw AppDataTransferError.invalidFolder }
        let groups = value.appGroupIdentifiers ?? []
        guard groups.count <= 64, Set(groups).count == groups.count,
              groups.allSatisfy(validGroupIdentifier), value.schema == 2 || groups.isEmpty else {
            throw AppDataTransferError.invalidFolder
        }
        for name in directories { try validateTreeRoot(root.appendingPathComponent(name)) }
        if !groups.isEmpty {
            try validateTreeRoot(root.appendingPathComponent("LCAppGroup"))
            for group in groups { try validateTreeRoot(root.appendingPathComponent("LCAppGroup/" + group)) }
        }
        guard Set((value.appGroupPreferences ?? [:]).keys) == Set(groups),
              (value.appGroupPreferences ?? [:]).values.allSatisfy({ names in
                  names.count <= 256 && Set(names).count == names.count && names.allSatisfy(validPreferenceName)
              }) else { throw AppDataTransferError.invalidFolder }
        let mainPreferences = value.appGroupMainPreferences ?? []
        guard Set(mainPreferences).count == mainPreferences.count,
              Set(mainPreferences).isSubset(of: Set((value.appGroupPreferences ?? [:]).values.flatMap { $0 })) else {
            throw AppDataTransferError.invalidFolder
        }
        return value
    }

    static func export(home: URL, destination: URL, identity: String, version: String, build: String,
                       appGroups: [String: URL] = [:]) throws -> URL {
        try separate(home, destination)
        try validateGroups(appGroups, home: home, external: destination)
        try validateTreeRoot(destination)
        let fm = FileManager.default
        let stage = destination.appendingPathComponent(".SideKickTransfer-" + UUID().uuidString)
        let result = destination.appendingPathComponent("SideKickData-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }
        for name in directories {
            let original = home.appendingPathComponent(name)
            let copy = stage.appendingPathComponent(name)
            try copyVerified(original, to: copy)
        }
        var preferences: [String: [String]] = [:]
        let mainPreferenceRoot = stage.appendingPathComponent("Library/Preferences")
        let mainPreferenceNames = fm.fileExists(atPath: mainPreferenceRoot.path)
            ? Set(try fm.contentsOfDirectory(at: mainPreferenceRoot, includingPropertiesForKeys: nil).map(\.lastPathComponent)) : []
        if !appGroups.isEmpty {
            let groupRoot = stage.appendingPathComponent("LCAppGroup")
            try fm.createDirectory(at: groupRoot, withIntermediateDirectories: false)
            for (group, source) in appGroups {
                let copy = groupRoot.appendingPathComponent(group)
                try copyGroup(source, to: copy)
                let sharedPreferences = copy.appendingPathComponent("Library/Preferences")
                var names = Set([group + ".plist"])
                if fm.fileExists(atPath: sharedPreferences.path) {
                    for file in try fm.contentsOfDirectory(at: sharedPreferences, includingPropertiesForKeys: [.isRegularFileKey]) {
                        guard validPreferenceName(file.lastPathComponent),
                              try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                        names.insert(file.lastPathComponent)
                        let destination = stage.appendingPathComponent("Library/Preferences/" + file.lastPathComponent)
                        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                        if fm.fileExists(atPath: destination.path) {
                            do { try verifyFile(file, destination) }
                            catch { throw AppDataTransferError.preferenceConflict }
                        } else { try copyVerifiedNode(file, to: destination) }
                    }
                }
                guard names.count <= 256, names.allSatisfy(validPreferenceName) else { throw AppDataTransferError.invalidFolder }
                preferences[group] = names.sorted()
            }
        }
        let metadata = AppDataTransferIdentity(schema: appGroups.isEmpty ? 1 : 2, bundleIdentifier: identity,
            version: version, build: build, appGroupIdentifiers: appGroups.isEmpty ? nil : appGroups.keys.sorted(),
            appGroupPreferences: appGroups.isEmpty ? nil : preferences,
            appGroupMainPreferences: appGroups.isEmpty ? nil : Set(preferences.values.flatMap { $0 }).intersection(mainPreferenceNames).sorted())
        let encoded = try JSONEncoder().encode(metadata)
        guard encoded.count < 65_536 else { throw AppDataTransferError.invalidFolder }
        try encoded.write(to: stage.appendingPathComponent(marker), options: .atomic)
        try fm.moveItem(at: stage, to: result)
        return result
    }

    /// Stages every tree before replacing any, restores originals on failure,
    /// and keeps a recovery generation after success. Absent guest files stay absent.
    @discardableResult
    static func restore(live: URL, home: URL, identity: String, version: String, build: String,
                        appGroups: [String: URL] = [:]) throws -> URL {
        try separate(live, home)
        let metadata = try readIdentity(at: live)
        guard metadata.bundleIdentifier == identity, metadata.version == version, metadata.build == build else {
            throw AppDataTransferError.identityMismatch
        }
        guard Set(metadata.appGroupIdentifiers ?? []) == Set(appGroups.keys) else { throw AppDataTransferError.appGroupUnavailable }
        try validateGroups(appGroups, home: home, external: live)
        try validateTreeRoot(home)
        let fm = FileManager.default
        let stage = home.appendingPathComponent(".SideKickRestore-" + UUID().uuidString)
        let rollback = home.appendingPathComponent(".SideKickRecovery-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }
        var replacements: [(destination: URL, staged: URL?, previous: URL)] = []
        for name in directories {
            try copyVerified(live.appendingPathComponent(name), to: stage.appendingPathComponent(name))
            try validateTreeRoot(home.appendingPathComponent(name))
            replacements.append((home.appendingPathComponent(name), stage.appendingPathComponent(name), rollback.appendingPathComponent(name)))
        }
        try fm.createDirectory(at: rollback, withIntermediateDirectories: false)
        // An App Group root is an OS-owned container: swap its user contents,
        // never the root or the container-manager metadata file.
        var groupStages: [URL] = []
        defer { for folder in groupStages { try? fm.removeItem(at: folder) } }
        for (group, native) in appGroups.sorted(by: { $0.key < $1.key }) {
            let guest = live.appendingPathComponent("LCAppGroup/" + group)
            let groupStage = native.appendingPathComponent(".SideKickRestore-" + UUID().uuidString)
            let groupRollback = native.appendingPathComponent(".SideKickRecovery-" + UUID().uuidString)
            groupStages.append(groupStage)
            try copyGroup(guest, to: groupStage)
            for name in metadata.appGroupPreferences?[group] ?? [] {
                let incoming = live.appendingPathComponent("Library/Preferences/" + name)
                let destination = groupStage.appendingPathComponent("Library/Preferences/" + name)
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                if fm.fileExists(atPath: incoming.path) {
                    try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try copyVerifiedNode(incoming, to: destination)
                }
            }
            try fm.createDirectory(at: groupRollback, withIntermediateDirectories: false)
            let incoming = Set(try groupChildren(groupStage).map(\.lastPathComponent))
            let existing = Set(try groupChildren(native).map(\.lastPathComponent))
            for name in incoming.union(existing).sorted() {
                replacements.append((native.appendingPathComponent(name), incoming.contains(name) ? groupStage.appendingPathComponent(name) : nil,
                                     groupRollback.appendingPathComponent(name)))
            }
        }
        // LiveContainer needs these mirrors in its home; the native app uses the
        // actual group container. Do not leave newly introduced stale duplicates.
        let mirroredPreferences = Set((metadata.appGroupPreferences ?? [:]).values.flatMap { $0 })
            .subtracting(metadata.appGroupMainPreferences ?? [])
        for name in mirroredPreferences {
            let mirror = stage.appendingPathComponent("Library/Preferences/" + name)
            if fm.fileExists(atPath: mirror.path) { try fm.removeItem(at: mirror) }
        }
        var moved: [(destination: URL, previous: URL?)] = []
        do {
            for item in replacements {
                let existed = fm.fileExists(atPath: item.destination.path)
                if existed { try fm.moveItem(at: item.destination, to: item.previous) }
                moved.append((item.destination, existed ? item.previous : nil))
                if let staged = item.staged { try fm.moveItem(at: staged, to: item.destination) }
            }
        } catch {
            // Preserve the recovery tree even when rollback itself cannot finish.
            let failure = error
            var rollbackFailure: Error?
            for item in moved.reversed() {
                do {
                    if fm.fileExists(atPath: item.destination.path) { try fm.removeItem(at: item.destination) }
                    if let previous = item.previous { try fm.moveItem(at: previous, to: item.destination) }
                } catch { rollbackFailure = error }
            }
            throw rollbackFailure ?? failure
        }
        return rollback
    }

    static func validGroupIdentifier(_ value: String) -> Bool {
        value.hasPrefix("group.") && value.utf8.count <= 255 &&
            value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { component in
                !component.isEmpty && component.utf8.allSatisfy {
                    (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
                }
            }
    }

    private static func validPreferenceName(_ name: String) -> Bool {
        name.hasSuffix(".plist") && name.utf8.count <= 255 &&
            !name.contains("/") && !name.contains("\\") && !name.contains("\0") &&
            !name.hasPrefix("com.apple.") && !name.hasPrefix("group.com.apple.") && name != ".GlobalPreferences.plist"
    }

    /// Resolve only groups actually granted to the helper. Never guess a container path.
    static func groupMappings(original: [String], entitled: [String]) throws -> [String: String] {
        guard original.count <= 64, Set(original).count == original.count,
              original.allSatisfy(validGroupIdentifier) else { throw AppDataTransferError.appGroupUnavailable }
        var result: [String: String] = [:]
        for group in original {
            let matches = entitled.filter { granted in
                if granted == group { return true }
                guard granted.hasPrefix(group + ".") else { return false }
                let suffix = granted.dropFirst(group.count + 1)
                return suffix.count == 10 && suffix.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) }
            }
            guard matches.count == 1 else { throw AppDataTransferError.appGroupUnavailable }
            result[group] = matches[0]
        }
        guard Set(result.values).count == result.count else { throw AppDataTransferError.appGroupUnavailable }
        return result
    }

    private static func validateGroups(_ groups: [String: URL], home: URL, external: URL) throws {
        guard groups.count <= 64, groups.keys.allSatisfy(validGroupIdentifier) else { throw AppDataTransferError.appGroupUnavailable }
        let roots = Array(groups.values)
        for (index, root) in roots.enumerated() {
            try validateTreeRoot(root)
            try separate(root, home)
            try separate(root, external)
            for previous in roots.prefix(index) { try separate(root, previous) }
        }
    }

    private static func groupChildren(_ root: URL) throws -> [URL] {
        try validateTreeRoot(root)
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { item in
            let name = item.lastPathComponent
            if name == ".com.apple.mobile_container_manager.metadata.plist" { return false }
            for prefix in [".SideKickRestore-", ".SideKickRecovery-"] where name.hasPrefix(prefix) {
                if UUID(uuidString: String(name.dropFirst(prefix.count))) != nil { return false }
            }
            try validateNode(item)
            return true
        }
    }

    private static func copyGroup(_ source: URL, to destination: URL) throws {
        let original = try groupChildren(source).sorted { $0.lastPathComponent < $1.lastPathComponent }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        for child in original { try copyVerifiedNode(child, to: destination.appendingPathComponent(child.lastPathComponent)) }
        guard try groupChildren(source).map(\.lastPathComponent).sorted() == original.map(\.lastPathComponent) else {
            throw AppDataTransferError.changedDuringCopy
        }
    }

    private static func copyVerifiedNode(_ source: URL, to destination: URL) throws {
        if try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
            try copyVerified(source, to: destination)
        } else {
            // Reuse the streaming verifier for individual group-root files too.
            try validateNode(source)
            try FileManager.default.copyItem(at: source, to: destination)
            try verifyFile(source, destination)
        }
    }

    private static func separate(_ a: URL, _ b: URL) throws {
        let a = a.standardizedFileURL.resolvingSymlinksInPath().path
        let b = b.standardizedFileURL.resolvingSymlinksInPath().path
        guard a != b, !a.hasPrefix(b + "/"), !b.hasPrefix(a + "/") else {
            throw AppDataTransferError.unsafeFile
        }
    }

    private static func validateTreeRoot(_ root: URL) throws {
        // Picker grants cover this root and its descendants, not its parents.
        // Walking into another app's sandbox ancestors would reject a valid grant.
        guard root.isFileURL else { throw AppDataTransferError.invalidFolder }
        try validateNode(root)
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw AppDataTransferError.invalidFolder
        }
    }

    private static func validateNode(_ node: URL) throws {
        let values = try node.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else {
            throw AppDataTransferError.unsafeFile
        }
    }

    private static func tree(_ root: URL) throws -> [String] {
        try validateTreeRoot(root)
        var result: [String] = []
        // Track relative components during traversal. On Apple platforms the
        // enumerator may return /private/var URLs for a /var input root.
        var pending: [(URL, String)] = [(root, "")]
        while let (folder, prefix) = pending.popLast() {
            for item in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: []) {
                try validateNode(item)
                let relative = prefix.isEmpty ? item.lastPathComponent : prefix + "/" + item.lastPathComponent
                result.append(relative)
                if try item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { pending.append((item, relative)) }
            }
        }
        return result.sorted()
    }

    private static func copyVerified(_ source: URL, to target: URL) throws {
        let paths = try tree(source)
        try FileManager.default.copyItem(at: source, to: target)
        guard try tree(source) == paths, try tree(target) == paths else { throw AppDataTransferError.changedDuringCopy }
        for path in paths {
            let original = source.appendingPathComponent(path)
            guard try original.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            try verifyFile(original, target.appendingPathComponent(path))
        }
    }

    private static func verifyFile(_ original: URL, _ target: URL) throws {
        let input = try FileHandle(forReadingFrom: original)
        defer { try? input.close() }
        let output = try FileHandle(forReadingFrom: target)
        defer { try? output.close() }
        while true {
            let a = try input.read(upToCount: 262_144) ?? Data()
            let b = try output.read(upToCount: 262_144) ?? Data()
            guard a == b else { throw AppDataTransferError.changedDuringCopy }
            if a.isEmpty { break }
        }
    }
}
