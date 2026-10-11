import Foundation
import UIKit

@MainActor
enum SideKickCertificateExport {
    static func present(callbackTemplate: String) {
        Task {
            do {
                if !DatabaseManager.shared.isStarted {
                    try await DatabaseManager.shared.start()
                }
                let certificate = try await SigningAccountStore().liveContainerCertificateForExport()
                guard let presenter = UIApplication.shared.topViewController() else { return }
                let alert = UIAlertController(
                    title: NSLocalizedString("Export Certificate", comment: ""),
                    message: NSLocalizedString("Do you want to export your certificate to an external app? That app will be able to sign apps using your certificate.", comment: ""),
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: NSLocalizedString("Export", comment: ""), style: .default) { _ in
                    guard callbackTemplate.contains("$(BASE64_CERT)") else {
                        ToastView(text: NSLocalizedString("No $(BASE64_CERT) placeholder found", comment: ""), detailText: nil).show(in: presenter)
                        return
                    }
                    var allowed = CharacterSet.urlQueryAllowed
                    allowed.remove(charactersIn: ";/?:@&=+$, #%")
                    guard let encodedPassword = certificate.password.addingPercentEncoding(withAllowedCharacters: allowed) else {
                        ToastView(text: NSLocalizedString("Failed to encode certificate password", comment: ""), detailText: nil).show(in: presenter)
                        return
                    }
                    var urlString = callbackTemplate.replacingOccurrences(of: "$(BASE64_CERT)", with: certificate.encodedBase64Certificate, options: .literal, range: nil)
                    urlString = urlString.replacingOccurrences(of: "$(PASSWORD)", with: encodedPassword, options: .literal, range: nil)
                    guard let callbackURL = URL(string: urlString) else {
                        ToastView(text: NSLocalizedString("Failed to initialize callback URL!", comment: ""), detailText: nil).show(in: presenter)
                        return
                    }
                    UIApplication.shared.open(callbackURL)
                })
                alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
                presenter.present(alert, animated: true)
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
