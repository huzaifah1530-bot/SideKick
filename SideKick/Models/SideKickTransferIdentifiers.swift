import Foundation

/// Bundle ID rewriting used when moving SideKick or its apps to another signing team.
enum SideKickTransferIdentifiers {
    /// Rewrites `identifier` when it is `oldID` or one of its child IDs (extensions).
    /// Returns `nil` for unrelated IDs, which must stay unchanged.
    static func rewrite(_ identifier: String, from oldID: String, to newID: String) -> String? {
        if identifier == oldID { return newID }
        guard identifier.hasPrefix(oldID + ".") else { return nil }
        return newID + identifier.dropFirst(oldID.count)
    }
}
