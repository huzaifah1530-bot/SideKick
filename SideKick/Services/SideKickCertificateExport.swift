import Foundation
import SideSign
import UIKit

@MainActor
enum SideKickCertificateExport {
    static func present(callbackTemplate: String) {
        Task {
            do {
                if !DatabaseManager.shared.isStarted {
                    try await DatabaseManager.shared.start()
                }
                try await SigningAccountStore().prepareCertificateForLiveContainerExport()
                ExportCertificateDialog.present(callbackTemplate: callbackTemplate)
            } catch {
                guard let presenter = UIApplication.shared.topViewController() else { return }
                let alert = UIAlertController(
                    title: "Signing Certificate Unavailable",
                    message: error.localizedDescription,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                presenter.present(alert, animated: true)
            }
        }
    }
}
