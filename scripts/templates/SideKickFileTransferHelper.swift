import UIKit
import UniformTypeIdentifiers

@MainActor
final class SideKickTransferPicker: NSObject, UIDocumentPickerDelegate {
    private var continuation: CheckedContinuation<URL, Error>?
    private static var active: SideKickTransferPicker?

    static func chooseFolder(title: String) async throws -> URL {
        guard active == nil else { throw AppDataTransferError.invalidFolder }
        let picker = SideKickTransferPicker()
        active = picker
        defer { active = nil }
        return try await withCheckedThrowingContinuation { continuation in
            picker.continuation = continuation
            let controller = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
            controller.delegate = picker
            controller.allowsMultipleSelection = false
            controller.title = title
            guard var presenter = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows }).first(where: { $0.isKeyWindow })?.rootViewController else {
                picker.finish(.failure(AppDataTransferError.invalidFolder))
                return
            }
            while let next = presenter.presentedViewController { presenter = next }
            presenter.present(controller, animated: true)
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if let url = urls.first { finish(.success(url)) }
        else { finish(.failure(AppDataTransferError.invalidFolder)) }
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish(.failure(CancellationError()))
    }
    private func finish(_ result: Result<URL, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

extension AppState {
    fileprivate func performSideKickFileTransfer(restoring: Bool) async {
        operationError = nil
        currentOperation = restoring ? .restore : .backup
        progressFraction = 0
        progressText = restoring
            ? "Close the LiveContainer guest, then choose its SideKickData folder. Its current Documents and Library will replace this app’s files."
            : "Choose a local folder in Files. A new SideKickData folder will be created there. Keychain and App Group data are not transferred."
        do {
            let url = try await SideKickTransferPicker.chooseFolder(title: restoring ? "Choose SideKickData folder" : "Choose export destination")
            guard url.startAccessingSecurityScopedResource() else { throw AppDataTransferError.invalidFolder }
            defer { url.stopAccessingSecurityScopedResource() }
            guard let identity = Bundle.main.bundleIdentifier,
                  let version = Bundle.main.object(forInfoDictionaryKey: "SideKickSourceVersion") as? String,
                  let build = Bundle.main.object(forInfoDictionaryKey: "SideKickSourceBuild") as? String else {
                throw AppDataTransferError.identityMismatch
            }
            let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath()
            progressText = restoring ? "Restoring app files…" : "Copying and verifying app files…"
            // Files are copied while the original app binary is replaced by this
            // helper. The original application cannot be mutating its databases.
            try await Task.detached {
                if restoring {
                    _ = try AppDataTransfer.restore(live: url, home: home, identity: identity, version: version, build: build)
                } else {
                    _ = try AppDataTransfer.export(home: home, destination: url, identity: identity, version: version, build: build)
                }
            }.value
            process(.success(()), errorTitle: "")
        } catch {
            process(.failure(error), errorTitle: "App data transfer did not finish")
        }
    }
}
