import Foundation
import UIKit

@MainActor
enum SideKickCertificateExport {
    private struct CallbackDestination {
        let template: String
        let scheme: String
        let description: String
    }

    static func present(callbackTemplate: String) {
        Task {
            do {
                try SideKickDataDirectory.prepareBeforeDatabaseStart()
                if !DatabaseManager.shared.isStarted {
                    try await DatabaseManager.shared.start()
                }
                let destination = try await validatedDestination(for: callbackTemplate)
                let recipients = try await SigningAccountStore().liveContainerCertificateRecipients()
                guard let presenter = UIApplication.shared.topViewController() else { return }
                guard !recipients.isEmpty else {
                    presentError("No installed LiveContainer app with an available signing identity was found.", in: presenter)
                    return
                }

                if recipients.count == 1, let recipient = recipients.first {
                    presentConsent(for: recipient, destination: destination, in: presenter)
                } else {
                    presentRecipientSelector(recipients, destination: destination, in: presenter)
                }
            } catch {
                guard let presenter = UIApplication.shared.topViewController() else { return }
                presentError(error.localizedDescription, in: presenter)
            }
        }
    }

    private static func validatedDestination(for callbackTemplate: String) async throws -> CallbackDestination {
        let certificateToken = "$(BASE64_CERT)"
        let passwordToken = "$(PASSWORD)"
        guard callbackTemplate.components(separatedBy: certificateToken).count == 2 else {
            throw CallbackError.missingCertificatePlaceholder
        }

        let marker = "SIDEKICK_CERTIFICATE_VALUE"
        let passwordMarker = "SIDEKICK_PASSWORD_VALUE"
        let validationTemplate = callbackTemplate
            .replacingOccurrences(of: certificateToken, with: marker, options: .literal)
            .replacingOccurrences(of: passwordToken, with: passwordMarker, options: .literal)
        guard !validationTemplate.contains("$("),
              let components = URLComponents(string: validationTemplate),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.fragment == nil,
              components.queryItems?.contains(where: { $0.value?.contains(marker) == true }) == true,
              !components.path.contains(marker) else {
            throw CallbackError.invalidDestination
        }

        let configuredSchemes = try await LiveContainerStore.shared.snapshot().connections.map { $0.scheme.lowercased() }
        let acceptedSchemes = Set(LiveContainerInstallation.knownSchemes + configuredSchemes)
        guard acceptedSchemes.contains(scheme) else { throw CallbackError.untrustedScheme }
        if callbackTemplate.contains(passwordToken),
           components.queryItems?.contains(where: { $0.value?.contains(passwordMarker) == true }) != true {
            throw CallbackError.invalidDestination
        }
        guard callbackTemplate.components(separatedBy: passwordToken).count <= 2 else {
            throw CallbackError.invalidDestination
        }

        let port = components.port.map { ":\($0)" } ?? ""
        let queryKeys = components.queryItems?.map(\.name) ?? []
        let querySuffix = queryKeys.isEmpty ? "" : "?" + queryKeys.joined(separator: "&")
        return CallbackDestination(
            template: callbackTemplate,
            scheme: scheme,
            description: "\(scheme)://\(host)\(port)\(components.path)\(querySuffix)"
        )
    }

    private static func presentRecipientSelector(
        _ recipients: [LiveContainerCertificateRecipient],
        destination: CallbackDestination,
        in presenter: UIViewController
    ) {
        let entries = recipients.enumerated().map { index, recipient in
            "\(index + 1). \(recipient.name) — \(recipient.signerDescription), \(recipient.teamName) (\(recipient.teamIdentifier)); \(recipient.bundleIdentifier)"
        }.joined(separator: "\n")
        let alert = UIAlertController(
            title: "Choose LiveContainer",
            message: "Choose the installed app and signing team for this export:\n\n\(entries)",
            preferredStyle: .alert
        )
        for (index, recipient) in recipients.enumerated() {
            let title = "\(index + 1). \(recipient.name) — \(recipient.teamIdentifier)"
            alert.addAction(UIAlertAction(title: title, style: .default) { _ in
                presentConsent(for: recipient, destination: destination, in: presenter)
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        presenter.present(alert, animated: true)
    }

    private static func presentConsent(
        for recipient: LiveContainerCertificateRecipient,
        destination: CallbackDestination,
        in presenter: UIViewController
    ) {
        let alert = UIAlertController(
            title: "Export Certificate to \(recipient.name)?",
            message: "This shares the signing certificate for \(recipient.signerDescription), team \(recipient.teamName) (\(recipient.teamIdentifier)), with the installed app \(recipient.bundleIdentifier). Destination: \(destination.description). The recipient can use this certificate to sign apps.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Export", style: .destructive) { _ in
            Task {
                do {
                    let certificate = try await SigningAccountStore().liveContainerCertificateForExport(to: recipient)
                    guard let callbackURL = makeCallbackURL(destination, certificate: certificate) else {
                        presentError("The certificate callback URL could not be created.", in: presenter)
                        return
                    }
                    await UIApplication.shared.open(callbackURL)
                } catch {
                    presentError(error.localizedDescription, in: presenter)
                }
            }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        presenter.present(alert, animated: true)
    }

    private static func makeCallbackURL(
        _ destination: CallbackDestination,
        certificate: (encodedBase64Certificate: String, password: String)
    ) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ";/?:@&=+$, #%")
        guard let encodedPassword = certificate.password.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        let urlString = destination.template
            .replacingOccurrences(of: "$(BASE64_CERT)", with: certificate.encodedBase64Certificate, options: .literal)
            .replacingOccurrences(of: "$(PASSWORD)", with: encodedPassword, options: .literal)
        guard let url = URL(string: urlString), url.scheme?.lowercased() == destination.scheme else { return nil }
        return url
    }

    private static func presentError(_ message: String, in presenter: UIViewController) {
        let alert = UIAlertController(title: "Signing Certificate Unavailable", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presenter.present(alert, animated: true)
    }

    private enum CallbackError: LocalizedError {
        case missingCertificatePlaceholder
        case invalidDestination
        case untrustedScheme

        var errorDescription: String? {
            switch self {
            case .missingCertificatePlaceholder:
                "The LiveContainer callback does not contain exactly one certificate placeholder."
            case .invalidDestination:
                "The LiveContainer callback URL is incomplete or has an invalid handoff format."
            case .untrustedScheme:
                "The callback scheme does not match a supported or configured LiveContainer installation."
            }
        }
    }
}
