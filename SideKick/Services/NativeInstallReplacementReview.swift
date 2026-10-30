import Foundation
import UIKit

/// Scoped inside the signing-account gate. Only new/imported package installs
/// request this review; normal refresh, re-sign and backup pipelines keep their own UI.
@MainActor
enum NativeInstallReplacementReview {
    private struct Request {
        let id = UUID()
        let expectedUpdateIdentifier: String?
    }
    private static var current: Request?

    static func withReview<T>(expectedUpdateIdentifier: String?, operation: () async throws -> T) async rethrows -> T {
        let previous = current
        current = Request(expectedUpdateIdentifier: expectedUpdateIdentifier)
        defer { current = previous }
        return try await operation()
    }

    /// Called with the signed bundle's final ID, after all user customizations,
    /// before the native installation or installed-app tracking data changes.
    static func review(finalIdentifier: String) async throws {
        guard let request = current else { return }
        guard !finalIdentifier.isEmpty, !finalIdentifier.contains("\0") else {
            throw OperationError.invalidParameters("The signed package has an invalid bundle ID.")
        }
        // A queued update is explicit permission for only that installed bundle ID.
        if finalIdentifier.caseInsensitiveCompare(request.expectedUpdateIdentifier ?? "") == .orderedSame { return }
        let installedName: String?
        do { installedName = try await lookupInstalledAppName(finalIdentifier) }
        catch {
            throw OperationError.invalidParameters("SideKick could not check whether this package would replace an installed app. Try again when the paired-device connection is available. \(error.localizedDescription)")
        }
        guard current?.id == request.id else { throw OperationError.cancelled }
        guard let installedName,
              let replacement = InstallReplacementPolicy.replacement(finalIdentifier: finalIdentifier,
                expectedUpdateIdentifier: request.expectedUpdateIdentifier,
                installed: [.init(identifier: finalIdentifier, name: installedName)]) else { return }
        guard UIApplication.shared.applicationState == .active,
              let presenter = UIApplication.shared.topViewController() else {
            throw OperationError.invalidParameters("SideKick could not show the replacement review. The installed app has not been changed. Try again with SideKick open.")
        }
        let accepted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let alert = UIAlertController(title: "Replace \(replacement.name)?",
                message: "This package targets the installed bundle ID \(replacement.identifier). Continuing will attempt to replace that app rather than create a separate copy. To keep both, cancel and use a different bundle ID. App data may be changed by the replacement.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in continuation.resume(returning: false) })
            alert.addAction(UIAlertAction(title: "Replace App", style: .destructive) { _ in continuation.resume(returning: true) })
            presenter.present(alert, animated: true)
        }
        guard accepted else { throw OperationError.cancelled }
    }
}
