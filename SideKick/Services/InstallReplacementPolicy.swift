import Foundation

enum InstallReplacementPolicy {
    struct InstalledTarget: Equatable, Sendable {
        let identifier: String
        let name: String
    }

    /// Certificate/account changes do not create a separate app when the final
    /// installed bundle ID is unchanged. An explicit update authorizes only its target.
    static func replacement(finalIdentifier: String, expectedUpdateIdentifier: String?,
                            installed: [InstalledTarget]) -> InstalledTarget? {
        guard !finalIdentifier.isEmpty else { return nil }
        if let expectedUpdateIdentifier,
           finalIdentifier.caseInsensitiveCompare(expectedUpdateIdentifier) == .orderedSame { return nil }
        return installed.first { $0.identifier.caseInsensitiveCompare(finalIdentifier) == .orderedSame }
    }
}
