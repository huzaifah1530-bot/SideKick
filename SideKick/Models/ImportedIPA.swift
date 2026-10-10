import Foundation

struct ImportedIPA: Codable, Identifiable, Hashable, Sendable {
    var id: String {
        guard let target = queuedForInstalledAppID else { return bundleIdentifier }
        return "queue:" + Data(bundleIdentifier.utf8).base64EncodedString() + ":" + Data(target.utf8).base64EncodedString()
    }
    let bundleIdentifier: String
    let name: String
    let version: String
    let fileName: String?
    let sourceBookmarkData: Data?
    let sourceURLString: String?
    let importedAt: Date
    let iconData: Data?
    var buildVersion: String? = nil
    var executableIdentity: String? = nil
    var sourceCreatedAt: Date? = nil
    var isQueuedForUpdate: Bool? = nil
    var queuedForInstalledAppID: String? = nil
    var githubUpdateKey: String? = nil
    var githubSourceIdentity: String? = nil
    var githubRepositoryURL: String? = nil
    var githubImportConfiguration: GitHubUpdateConfiguration? = nil

    // Before queue state was persisted, every retained IPA matching an installed app
    // came from the explicit "Queue for Update" choice.
    var isUpdateQueued: Bool { isQueuedForUpdate ?? true }

    var formattedImportDate: String {
        importedAt.formatted(date: .abbreviated, time: .omitted)
    }
}

enum IPAImportError: LocalizedError {
    case notAnIPA
    case invalidArchive
    case missingAppBundle
    case missingBundleIdentifier
    case inaccessibleFile
    case sourceFileMissing
    case sourceBookmarkUnavailable
    case bundleIdentifierMismatch(String, String)

    var errorDescription: String? {
        switch self {
        case .notAnIPA: "Choose an .ipa file."
        case .invalidArchive: "This file is not a valid IPA archive."
        case .missingAppBundle: "No iOS app bundle was found inside this IPA."
        case .missingBundleIdentifier: "The app's Info.plist has no bundle identifier."
        case .inaccessibleFile: "SideKick could not access the selected file. Try saving it to Files first."
        case .sourceFileMissing: "The original IPA can’t be found. It may have been moved or deleted. Choose the file again to use this app."
        case .sourceBookmarkUnavailable: "SideKick couldn’t save access to the original file. Choose it again from Files."
        case .bundleIdentifierMismatch(let expected, let actual): "This IPA is for \(actual), not \(expected). It wasn’t queued as an update."
        }
    }
}

// Metadata edits move the same import; distinct installations retain distinct queues.
enum IPAImportIndex {
    static func replacing(_ app: ImportedIPA, in entries: [ImportedIPA]) -> [ImportedIPA] {
        [app] + entries.filter {
            $0.id != app.id && !($0.bundleIdentifier == app.bundleIdentifier && $0.importedAt == app.importedAt)
        }
    }
}
