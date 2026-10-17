import Foundation

/// Saved just before an update installs. Installing SideKick itself ends the app, so the
/// "Successfully updated" sheet is shown on the next launch once the new version is detected.
struct UpdateSuccessRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String { bundleIdentifier + "|" + newVersion + "|" + newBuild }
    let bundleIdentifier: String
    let appName: String
    let oldVersion: String
    let newVersion: String
    let newBuild: String
    let iconData: Data?
    /// Present only for GitHub releases. Actions and manual installs show no notes.
    var releaseTitle: String?
    var releaseNotes: String?
    let startedAt: Date

    private static let key = "sidekick.update.pending-success"

    static func pending() -> [UpdateSuccessRecord] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let records = try? JSONDecoder().decode([UpdateSuccessRecord].self, from: data) else { return [] }
        // A record that never matched an install within a day belongs to a failed attempt.
        return records.filter { $0.startedAt > .now.addingTimeInterval(-86_400) }
    }

    func save() {
        var records = Self.pending().filter { $0.bundleIdentifier != bundleIdentifier }
        records.append(self)
        Self.store(records)
    }

    static func remove(_ record: UpdateSuccessRecord) {
        store(pending().filter { $0 != record })
    }

    static func remove(bundleIdentifier: String) {
        store(pending().filter { $0.bundleIdentifier != bundleIdentifier })
    }

    private static func store(_ records: [UpdateSuccessRecord]) {
        if records.isEmpty { UserDefaults.standard.removeObject(forKey: key); return }
        if let data = try? JSONEncoder().encode(records) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// The first record whose app now reports the new version.
    static func completed(installed: [(bundleIdentifier: String, version: String, build: String)]) -> UpdateSuccessRecord? {
        for record in pending() {
            if installed.contains(where: { $0.bundleIdentifier == record.bundleIdentifier
                && $0.version == record.newVersion && $0.build == record.newBuild }) {
                return record
            }
        }
        return nil
    }

    /// Release notes for a GitHub release key ("release-v2:<releaseID>:…"). Nil for Actions builds.
    static func releaseNotes(updateKey: String?, repositoryURL: String?, token: String?) async -> (title: String?, body: String?)? {
        guard let updateKey, updateKey.hasPrefix("release-v2:") || updateKey.hasPrefix("release:"),
              let releaseID = updateKey.split(separator: ":").dropFirst().first,
              let repositoryURL, let url = URL(string: GitHubSourceIdentity.repository(repositoryURL)) else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 2 else { return nil }
        guard let apiURL = URL(string: "https://api.github.com/repos/\(parts[0])/\(parts[1])/releases/\(releaseID)") else { return nil }
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SideKick iOS app", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        struct Release: Decodable { let name: String?; let tag_name: String?; let body: String? }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data) else { return nil }
        let body = release.body?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (release.name ?? release.tag_name, body?.isEmpty == false ? body : nil)
    }
}
