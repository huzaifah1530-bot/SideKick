import Foundation

struct AppDataTransferIdentity: Codable, Equatable {
    let schema: Int
    let bundleIdentifier: String
    let version: String
    let build: String
}

enum AppDataTransferError: LocalizedError {
    case invalidFolder, identityMismatch, unsafeFile, changedDuringCopy
    var errorDescription: String? {
        switch self {
        case .invalidFolder: "Choose the exported SideKick data folder containing Documents, Library and SideKickTransfer.json."
        case .identityMismatch: "This data belongs to another app or app version. Restore using the original signing identity and matching version."
        case .unsafeFile: "The transfer contains a link or unsupported file. No native data was replaced."
        case .changedDuringCopy: "Files changed while being copied. Close the guest completely and try again."
        }
    }
}

/// Shared by SideKick and the native sandbox helper. LiveContainer owns guest
/// registration; this engine transfers files only, never Keychain or App Groups.
enum AppDataTransfer {
    static let marker = "SideKickTransfer.json"
    private static let directories = ["Documents", "Library"]

    static func readIdentity(at root: URL) throws -> AppDataTransferIdentity {
        try validateTreeRoot(root)
        let file = root.appendingPathComponent(marker)
        try validateNode(file)
        guard (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max < 16_384 else {
            throw AppDataTransferError.invalidFolder
        }
        let value = try JSONDecoder().decode(AppDataTransferIdentity.self, from: Data(contentsOf: file))
        guard value.schema == 1 else { throw AppDataTransferError.invalidFolder }
        for name in directories { try validateTreeRoot(root.appendingPathComponent(name)) }
        return value
    }

    static func export(home: URL, destination: URL, identity: String, version: String, build: String) throws -> URL {
        try separate(home, destination)
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
        let metadata = AppDataTransferIdentity(schema: 1, bundleIdentifier: identity, version: version, build: build)
        try JSONEncoder().encode(metadata).write(to: stage.appendingPathComponent(marker), options: .atomic)
        try fm.moveItem(at: stage, to: result)
        return result
    }

    /// Stages both trees before replacing either, restores originals on failure,
    /// and keeps a recovery generation after success. Absent guest files stay absent.
    @discardableResult
    static func restore(live: URL, home: URL, identity: String, version: String, build: String) throws -> URL {
        try separate(live, home)
        let expected = AppDataTransferIdentity(schema: 1, bundleIdentifier: identity, version: version, build: build)
        guard try readIdentity(at: live) == expected else { throw AppDataTransferError.identityMismatch }
        try validateTreeRoot(home)
        let fm = FileManager.default
        let stage = home.appendingPathComponent(".SideKickRestore-" + UUID().uuidString)
        let rollback = home.appendingPathComponent(".SideKickRecovery-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }
        for name in directories {
            try copyVerified(live.appendingPathComponent(name), to: stage.appendingPathComponent(name))
            try validateTreeRoot(home.appendingPathComponent(name))
        }
        try fm.createDirectory(at: rollback, withIntermediateDirectories: false)
        var moved: [String] = []
        do {
            for name in directories {
                let original = home.appendingPathComponent(name)
                try fm.moveItem(at: original, to: rollback.appendingPathComponent(name))
                moved.append(name)
                try fm.moveItem(at: stage.appendingPathComponent(name), to: original)
            }
        } catch {
            // Preserve the recovery tree even when rollback itself cannot finish.
            for name in moved.reversed() {
                let original = home.appendingPathComponent(name)
                if fm.fileExists(atPath: original.path) { try fm.removeItem(at: original) }
                try fm.moveItem(at: rollback.appendingPathComponent(name), to: original)
            }
            throw error
        }
        return rollback
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
        var pending = [root]
        while let folder = pending.popLast() {
            for item in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: []) {
                try validateNode(item)
                result.append(String(item.path.dropFirst(root.path.count + 1)))
                if try item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { pending.append(item) }
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
            let input = try FileHandle(forReadingFrom: original)
            defer { try? input.close() }
            let output = try FileHandle(forReadingFrom: target.appendingPathComponent(path))
            defer { try? output.close() }
            while true {
                let a = try input.read(upToCount: 262_144) ?? Data()
                let b = try output.read(upToCount: 262_144) ?? Data()
                guard a == b else { throw AppDataTransferError.changedDuringCopy }
                if a.isEmpty { break }
            }
        }
    }
}
