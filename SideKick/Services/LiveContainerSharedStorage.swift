import Foundation

/// Where LiveContainer keeps shared apps, and how it chooses an installation to run them.
/// Mirrors LiveContainer's LCSharedUtils (appGroupID, findBundleWithBundleId,
/// lcUrlSchemes and containerLock) so SideKick reads the same folder and launches the
/// same way LiveContainer's own Shortcuts action does. SideKick never writes here.
enum LiveContainerSharedStorage {
    /// LiveContainer borrows its store's App Group. Signing appends the team ID.
    static let groupBases = ["group.com.SideStore.SideStore", "group.com.rileytestut.AltStore"]
    /// Only the first installation manages apps; the others can only run shared apps.
    static let primaryScheme = "livecontainer"

    /// Groups this app holds that LiveContainer could be using, in LiveContainer's order.
    static func candidateGroups(_ groups: [String]) -> [String] {
        groupBases.flatMap { base in groups.filter { $0 == base || $0.hasPrefix(base + ".") } }
    }

    /// The group LiveContainer uses: one with the store's `Apps` folder wins, otherwise
    /// the first that resolves. `container` maps a group to its container URL.
    static func liveContainerGroup(from groups: [String], container: (String) -> URL?,
                                   fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> (id: String, url: URL)? {
        let resolved = candidateGroups(groups).compactMap { group in container(group).map { (id: group, url: $0) } }
        return resolved.first { fileExists($0.url.appendingPathComponent("Apps")) } ?? resolved.first
    }

    static func applicationsDirectory(in container: URL) -> URL {
        container.appendingPathComponent("LiveContainer/Applications", isDirectory: true)
    }

    static func containerLockURL(in container: URL) -> URL {
        container.appendingPathComponent("LiveContainer/containerLock.plist")
    }

    /// Installation to open a shared app with, like LiveContainer's launch action:
    /// one already running this app's data, else the first installed in the user's order.
    /// - Parameters:
    ///   - dataFolder: the guest's `LCDataUUID`.
    ///   - installed: schemes iOS reports as installed.
    ///   - priority: LiveContainer's `LCMultiLaunchPriority` setting, if any.
    ///   - containerLock: contents of `containerLock.plist`, if readable.
    static func launchScheme(dataFolder: String?, installed: Set<String>, priority: [Any]?, containerLock: [String: Any]?) -> String {
        if let dataFolder, let usage = containerLock?[dataFolder] as? [String: Any],
           var running = (usage["runningLC"] as? String)?.lowercased() {
            // A multitasking process reports "<scheme>.liveprocess".
            if running.hasSuffix(".liveprocess") { running = String(running.dropLast(".liveprocess".count)) }
            if installed.contains(running) { return running }
        }
        return orderedSchemes(priority: priority).first(where: installed.contains) ?? primaryScheme
    }

    /// LiveContainer's lcUrlSchemes: saved priority first, then the defaults, no duplicates.
    static func orderedSchemes(priority: [Any]?) -> [String] {
        let defaults = LiveContainerInstallation.knownSchemes
        var result: [String] = []
        for case let scheme as String in priority ?? [] {
            let scheme = scheme.lowercased()
            if defaults.contains(scheme), !result.contains(scheme) { result.append(scheme) }
        }
        return result + defaults.filter { !result.contains($0) }
    }
}
