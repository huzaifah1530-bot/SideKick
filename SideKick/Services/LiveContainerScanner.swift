import Foundation

enum LiveContainerScanner {
    static func scan(directory: URL, connectionID: UUID, folder: String) throws -> LiveContainerGuest {
        try Task.checkCancellation()
        guard directory.lastPathComponent == "Applications",
              let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else { throw LiveContainerError.invalidDirectory }
        guard !folder.isEmpty, folder == (folder as NSString).lastPathComponent,
              folder != ".", folder != "..", folder.utf8.count <= 1024 else {
            throw LiveContainerError.guestMissing
        }

        let bundle = directory.appendingPathComponent(folder, isDirectory: true)
        try OwnedStoragePath.validate(bundle, inside: directory)
        let bundleValues = try bundle.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard bundle.pathExtension.lowercased() == "app",
              bundleValues.isDirectory == true, bundleValues.isSymbolicLink != true else { throw LiveContainerError.guestMissing }
        try Task.checkCancellation()

        let info = try plist(bundle.appendingPathComponent("Info.plist"), root: directory)
        guard info["LCBundleIdentifier"] == nil else {
            throw LiveContainerError.invalidMetadata("Signing is incomplete; retry after LiveContainer finishes.")
        }
        var identifier = string(info["CFBundleIdentifier"])
        var dataFolder: String?
        let supplemental = bundle.appendingPathComponent("LCAppInfo.plist")
        if FileManager.default.fileExists(atPath: supplemental.path) {
            let lcInfo = try plist(supplemental, root: directory)
            if lcInfo["doUseLCBundleId"] as? Bool == true {
                identifier = string(lcInfo["LCOrignalBundleIdentifier"])
            }
            dataFolder = string(lcInfo["LCDataUUID"])
        }
        guard let identifier, !identifier.isEmpty else {
            throw LiveContainerError.invalidMetadata("Info.plist has no usable bundle identifier.")
        }
        let name = string(info["CFBundleDisplayName"]) ?? string(info["CFBundleName"]) ?? bundle.deletingPathExtension().lastPathComponent
        let build = string(info["CFBundleVersion"]) ?? "Unknown"
        let version = string(info["CFBundleShortVersionString"]) ?? build
        let guest = LiveContainerGuest(
            connectionID: connectionID,
            folder: folder,
            name: name,
            bundleIdentifier: identifier,
            version: version,
            build: build,
            iconData: nil,
            lastSeen: .now
        )
        var stamp = [version, build]
        for file in ["Info.plist", string(info["CFBundleExecutable"])].compactMap({ $0 }) {
            let url = bundle.appendingPathComponent(file)
            if (try? OwnedStoragePath.validate(url, inside: directory)) != nil,
               let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
                stamp.append("\(values.fileSize ?? 0):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)")
            }
        }
        var validated = guest
        validated.dataFolder = dataFolder
        validated.observation = stamp.joined(separator: "|")
        validated.executableIdentity = executableIdentity(info: info, bundle: bundle, root: directory)
        return validated
    }

    static func scan(directory: URL, connectionID: UUID) throws -> LiveContainerScan {
        try Task.checkCancellation()
        let manager = FileManager.default
        guard directory.lastPathComponent == "Applications",
              let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else { throw LiveContainerError.invalidDirectory }
        let children = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard children.count <= 5000 else { throw LiveContainerError.invalidMetadata("This directory contains too many entries to scan safely.") }
        var result = LiveContainerScan()
        var iconBudget = 32 * 1024 * 1024
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where child.pathExtension.lowercased() == "app" {
            try Task.checkCancellation()
            do {
                try OwnedStoragePath.validate(child, inside: directory)
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { throw LiveContainerError.invalidMetadata("Not a readable app bundle.") }
                let info = try plist(child.appendingPathComponent("Info.plist"), root: directory)
                // A temporary signing state must never be repaired by discovery.
                guard info["LCBundleIdentifier"] == nil else { throw LiveContainerError.invalidMetadata("Signing is incomplete; retry after LiveContainer finishes.") }
                var identifier = string(info["CFBundleIdentifier"])
                var dataFolder: String?
                let supplemental = child.appendingPathComponent("LCAppInfo.plist")
                if manager.fileExists(atPath: supplemental.path) {
                    let lcInfo = try plist(supplemental, root: directory)
                    if lcInfo["doUseLCBundleId"] as? Bool == true {
                        identifier = string(lcInfo["LCOrignalBundleIdentifier"])
                    }
                    dataFolder = string(lcInfo["LCDataUUID"])
                }
                guard let identifier, !identifier.isEmpty else { throw LiveContainerError.invalidMetadata("Info.plist has no usable bundle identifier.") }
                let name = string(info["CFBundleDisplayName"]) ?? string(info["CFBundleName"]) ?? child.deletingPathExtension().lastPathComponent
                let build = string(info["CFBundleVersion"]) ?? "Unknown"
                let version = string(info["CFBundleShortVersionString"]) ?? build
                let icon = iconData(info: info, bundle: child, root: directory, budget: iconBudget)
                iconBudget -= icon?.count ?? 0
                var guest = LiveContainerGuest(connectionID: connectionID, folder: child.lastPathComponent,
                    name: name, bundleIdentifier: identifier, version: version, build: build, iconData: icon, lastSeen: .now)
                var stamp = [version, build]
                for file in ["Info.plist", string(info["CFBundleExecutable"])].compactMap({ $0 }) {
                    let url = child.appendingPathComponent(file)
                    if (try? OwnedStoragePath.validate(url, inside: directory)) != nil,
                       let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
                        stamp.append("\(values.fileSize ?? 0):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)")
                    }
                }
                guest.observation = stamp.joined(separator: "|")
                guest.dataFolder = dataFolder
                guest.executableIdentity = executableIdentity(info: info, bundle: child, root: directory)
                result.apps.append(guest)
            } catch is CancellationError { throw CancellationError() }
            catch {
                result.failedFolders.append(child.lastPathComponent)
                result.warnings.append("\(child.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return result
    }

    private static func executableIdentity(info: [String: Any], bundle: URL, root: URL) -> String? {
        guard let name = string(info["CFBundleExecutable"]), name == (name as NSString).lastPathComponent else { return nil }
        let executable = bundle.appendingPathComponent(name)
        guard (try? OwnedStoragePath.validate(executable, inside: root)) != nil,
              let handle = try? FileHandle(forReadingFrom: executable) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 32),
              let size = GitHubExecutableIdentity.metadataRegionSize(header, maximumSize: 1024 * 1024),
              let commands = try? handle.read(upToCount: size - 32) else { return nil }
        return GitHubExecutableIdentity.read(header + commands)
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String, value.utf8.count <= 1024,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private static func plist(_ url: URL, root: URL) throws -> [String: Any] {
        try OwnedStoragePath.validate(url, inside: root)
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1024 * 1024 else {
            throw LiveContainerError.invalidMetadata("Metadata exceeds the 1 MB limit.")
        }
        try Task.checkCancellation()
        let data = try Data(contentsOf: url)
        try Task.checkCancellation()
        guard data.count <= 1024 * 1024,
              let info = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw LiveContainerError.invalidMetadata("Info.plist is not a metadata dictionary.")
        }
        return info
    }

    private static func iconData(info: [String: Any], bundle: URL, root: URL, budget: Int) -> Data? {
        guard budget > 0 else { return nil }
        let icons = info["CFBundleIcons"] as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let names = primary?["CFBundleIconFiles"] as? [String] ?? info["CFBundleIconFiles"] as? [String] ?? []
        for name in names.reversed().prefix(10) where !name.contains("/") && !name.contains("\\") {
            let base = (name as NSString).deletingPathExtension
            for file in [name, base + "@3x.png", base + "@2x.png", base + ".png"] {
                let url = bundle.appendingPathComponent(file)
                guard (try? OwnedStoragePath.validate(url, inside: root)) != nil,
                      let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size <= min(budget, 4 * 1024 * 1024), let data = try? Data(contentsOf: url),
                      data.count <= min(budget, 4 * 1024 * 1024) else { continue }
                return data
            }
        }
        return nil
    }
}
