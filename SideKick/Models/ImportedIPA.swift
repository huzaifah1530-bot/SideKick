import Foundation

struct ImportedIPA: Codable, Identifiable, Hashable, Sendable {
    var id: String { bundleIdentifier }
    let bundleIdentifier: String
    let name: String
    let version: String
    let fileName: String
    let importedAt: Date

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

    var errorDescription: String? {
        switch self {
        case .notAnIPA: "Choose an .ipa file."
        case .invalidArchive: "This file is not a valid IPA archive."
        case .missingAppBundle: "No iOS app bundle was found inside this IPA."
        case .missingBundleIdentifier: "The app's Info.plist has no bundle identifier."
        case .inaccessibleFile: "SideKick could not access the selected file. Try saving it to Files first."
        }
    }
}
