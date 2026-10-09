import Foundation

actor GitHubUpdateConfigurationStore {
    private let fileManager = FileManager.default
    private let fileURL: URL

    init() {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        fileURL = support.appendingPathComponent("GitHubUpdates", isDirectory: true).appendingPathComponent("apps.json")
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
    }

    func remove(bundleIdentifier: String) throws {
        let values = try all().filter { $0.bundleIdentifier != bundleIdentifier }
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(values).write(to: fileURL, options: .atomic)
    }
}
