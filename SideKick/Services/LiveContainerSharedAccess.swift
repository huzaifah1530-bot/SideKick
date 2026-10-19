import UIKit

/// Device side of `LiveContainerSharedStorage`: reads LiveContainer's App Group when
/// SideKick's signature grants it (same Apple ID as LiveContainer), finds shared apps
/// automatically, and launches or installs them the way LiveContainer expects.
@MainActor
enum LiveContainerSharedAccess {
    private static let linkedPathKey = "sidekick.livecontainer.shared-linked-path.v1"

    enum Status: Equatable {
        /// Shared apps folder found.
        case available(URL)
        /// SideKick can read the group, but LiveContainer hasn't created shared storage there.
        case noSharedFolder
        /// SideKick isn't signed with LiveContainer's group (different Apple ID, or not re-signed yet).
        case notGranted
    }

    static var container: (id: String, url: URL)? {
        LiveContainerSharedStorage.liveContainerGroup(from: Bundle.main.appGroups) {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
        }
    }

    static var status: Status {
        guard let container else { return .notGranted }
        let directory = LiveContainerSharedStorage.applicationsDirectory(in: container.url)
        return FileManager.default.fileExists(atPath: directory.path) ? .available(directory) : .noSharedFolder
    }

    static var installedSchemes: Set<String> {
        Set(LiveContainerInstallation.knownSchemes.filter { scheme in
            URL(string: scheme + "://").map(UIApplication.shared.canOpenURL) ?? false
        })
    }

    /// The installation that should open a shared app now.
    static func launchScheme(for guest: LiveContainerGuest) -> String {
        let group = container
        let priority = group.flatMap { UserDefaults(suiteName: $0.id)?.array(forKey: "LCMultiLaunchPriority") }
        let lock = group.flatMap { NSDictionary(contentsOf: LiveContainerSharedStorage.containerLockURL(in: $0.url)) as? [String: Any] }
        return LiveContainerSharedStorage.launchScheme(dataFolder: guest.dataFolder, installed: installedSchemes,
                                                       priority: priority, containerLock: lock)
    }

    /// Adds the shared apps folder as a connection the first time it is found at this path.
    /// A user who forgets it later isn't overridden; they can add it again from the folder list.
    static func linkIfNeeded(using store: LiveContainerStore) async {
        guard case .available(let directory) = status,
              UserDefaults.standard.string(forKey: linkedPathKey) != directory.path else { return }
        await link(directory, using: store)
    }

    @discardableResult
    static func link(_ directory: URL, using store: LiveContainerStore) async -> Error? {
        do {
            try await store.link(directory: directory, name: LiveContainerInstallation.connectionName(
                scheme: LiveContainerSharedStorage.primaryScheme, storageKind: .sharedDirectory),
                scheme: LiveContainerSharedStorage.primaryScheme, storageKind: .sharedDirectory)
        } catch LiveContainerError.alreadyLinked {
        } catch {
            debugLog("[SideKick] Could not link LiveContainer's shared apps: \(error.localizedDescription)")
            return error
        }
        UserDefaults.standard.set(directory.path, forKey: linkedPathKey)
        return nil
    }

    // MARK: Installing updates

    /// SideKick's own folder in the shared container; LiveContainer's folders are never written.
    private static func handoffFolder(in container: URL) -> URL {
        container.appendingPathComponent("SideKick/LiveContainerHandoff", isDirectory: true)
    }

    /// Copies an IPA where LiveContainer can read it and returns LiveContainer 1's install
    /// link. Only the first installation can install or replace apps, shared ones included.
    /// Returns nil when that route isn't available, so the caller can use the share sheet.
    static func installURL(copying ipa: URL) throws -> URL? {
        guard let container, installedSchemes.contains(LiveContainerSharedStorage.primaryScheme) else { return nil }
        removeHandoffs()
        let folder = handoffFolder(in: container.url).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // LiveContainer only installs files ending in .ipa or .tipa.
        let name = ipa.pathExtension.lowercased() == "ipa" ? ipa.lastPathComponent : ipa.deletingPathExtension().lastPathComponent + ".ipa"
        let target = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: ipa, to: target)
        var components = URLComponents()
        components.scheme = LiveContainerSharedStorage.primaryScheme
        components.host = "install"
        components.queryItems = [URLQueryItem(name: "url", value: target.absoluteString)]
        return components.url
    }

    /// LiveContainer reads the IPA in place and leaves it, so old copies are removed here.
    static func removeHandoffs(olderThan age: TimeInterval = 86_400) {
        guard let container else { return }
        let manager = FileManager.default
        let root = handoffFolder(in: container.url)
        guard let folders = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for folder in folders {
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if created < Date.now.addingTimeInterval(-age) { try? manager.removeItem(at: folder) }
        }
    }
}
