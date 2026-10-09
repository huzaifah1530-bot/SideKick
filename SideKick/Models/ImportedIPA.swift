import Foundation

struct ImportedIPA: Codable, Identifiable, Hashable, Sendable {
    var id: String { bundleIdentifier }
    let bundleIdentifier: String
    let name: String
    let version: String
    let fileName: String?
    let sourceBookmarkData: Data?
    let sourceURLString: String?
    let importedAt: Date
    let iconData: Data?

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
