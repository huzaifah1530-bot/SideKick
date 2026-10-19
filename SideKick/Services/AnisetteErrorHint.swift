import Foundation

/// Points users at the server refresh when a failure came from Anisette, in case
/// the server they use was patched and a newer one is listed on GitHub.
enum AnisetteErrorHint {
    static let suggestion = "This looks like an Anisette server problem. Go to Settings → Advanced → Anisette and tap Use Newest Anisette Server to try the latest recommended server."

    static func isAnisetteRelated(_ error: Error) -> Bool {
        isAnisetteRelated(error as NSError, depth: 0)
    }

    /// The error's description, plus the suggestion when Anisette caused it.
    static func message(for error: Error) -> String {
        let description = error.localizedDescription
        guard isAnisetteRelated(error), !description.contains(suggestion) else { return description }
        return description + "\n\n" + suggestion
    }

    private static func isAnisetteRelated(_ error: NSError, depth: Int) -> Bool {
        guard depth < 6 else { return false }
        if error.domain.localizedCaseInsensitiveContains("anisette")
            || error.localizedDescription.localizedCaseInsensitiveContains("anisette") { return true }
        var underlying: [NSError] = []
        if let error = error.userInfo[NSUnderlyingErrorKey] as? NSError { underlying.append(error) }
        if let errors = error.userInfo["NSMultipleUnderlyingErrorsKey"] as? [NSError] { underlying += errors }
        return underlying.contains { isAnisetteRelated($0, depth: depth + 1) }
    }
}
