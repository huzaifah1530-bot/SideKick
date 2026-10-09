import Foundation

enum AppSharingError: LocalizedError {
    case invalidUploadResponse
    case uploadFailed(Int)
    case downloadFailed(Int)
    case invalidShareLink
    case insecureURL

    var errorDescription: String? {
        switch self {
        case .invalidUploadResponse:
            return "The upload service returned an unrecognized link."
        case .uploadFailed(let status):
            return "The upload service couldn’t upload this IPA (HTTP \(status)). Try again later."
        case .downloadFailed(let status):
            return "The file host couldn’t provide this IPA (HTTP \(status)). Check the link and try again."
        case .invalidShareLink:
            return "This SideKick link is invalid or has expired."
        case .insecureURL:
            return "For safety, SideKick only downloads IPA files from HTTPS links."
        }
    }
}

struct BuzzheavierClient {
    func upload(ipaURL: URL, fileName: String) async throws -> URL {
        let safeName = fileName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let encodedName = safeName.addingPercentEncoding(withAllowedCharacters: allowed),
              let uploadURL = URL(string: "https://w.buzzheavier.com/\(encodedName)") else {
            throw AppSharingError.invalidUploadResponse
        }

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: ipaURL)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw AppSharingError.uploadFailed(status)
        }

        guard
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let fileID = (payload["id"] as? String)
                ?? ((payload["data"] as? [String: Any])?["id"] as? String),
            !fileID.isEmpty,
            fileID.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil,
            let shareURL = URL(string: "https://buzzheavier.com/\(fileID)")
        else {
            throw AppSharingError.invalidUploadResponse
        }
        return shareURL
    }

    func resolveDownloadURL(from shareURL: URL) async throws -> URL {
        guard let host = shareURL.host?.lowercased(),
              host == "buzzheavier.com" || host == "www.buzzheavier.com" else { return shareURL }

        var pageURL = shareURL
        if shareURL.pathComponents.count == 2 {
            var components = URLComponents(url: shareURL, resolvingAgainstBaseURL: false)
            components?.path = "/d\(shareURL.path)"
            pageURL = components?.url ?? shareURL
        }
        guard pageURL.pathComponents.count >= 3,
              pageURL.pathComponents[1] == "d" else { return shareURL }

        var request = URLRequest(url: pageURL.appendingPathComponent("download"))
        request.setValue("true", forHTTPHeaderField: "HX-Request")
        request.setValue(pageURL.absoluteString, forHTTPHeaderField: "HX-Current-URL")
        request.setValue(pageURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("SideKick", forHTTPHeaderField: "User-Agent")
        // Do not allow URLSession to follow the download redirect here. If it
        // does, `data(for:)` can buffer the entire IPA in memory just to learn
        // its final URL. The redirect response contains the destination.
        let session = URLSession(
            configuration: .ephemeral,
            delegate: RedirectBlockingDelegate(),
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw AppSharingError.invalidShareLink
        }

        let redirect = response.value(forHTTPHeaderField: "HX-Redirect")
            ?? response.value(forHTTPHeaderField: "Location")
        guard let redirect,
              let resolvedURL = URL(string: redirect, relativeTo: request.url)?.absoluteURL,
              resolvedURL.scheme?.lowercased() == "https" else {
            throw AppSharingError.invalidShareLink
        }
        return resolvedURL
    }

    func download(from shareURL: URL) async throws -> (URL, URLResponse) {
        let downloadURL = try await resolveDownloadURL(from: shareURL)
        var request = URLRequest(url: downloadURL)
        request.setValue("SideKick", forHTTPHeaderField: "User-Agent")
        request.setValue(shareURL.absoluteString, forHTTPHeaderField: "Referer")
        return try await URLSession.shared.download(for: request)
    }
}

private final class RedirectBlockingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum SideKickShareLink {
    static let importNotification = Notification.Name("SideKick.ImportFromShareLink")
    static let urlKey = "url"
    private static let pendingURLKey = "sidekick.pending-share-import-url"

    static func make(for downloadURL: URL) -> URL? {
        guard downloadURL.scheme?.lowercased() == "https" else { return nil }
        let encoded = Data(downloadURL.absoluteString.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return URL(string: "sidekick://import/\(encoded)")
    }

    @discardableResult
    static func handle(_ url: URL) -> Bool {
        guard let downloadURL = downloadURL(from: url) else { return false }

        UserDefaults.standard.set(downloadURL.absoluteString, forKey: pendingURLKey)
        NotificationCenter.default.post(
            name: importNotification,
            object: nil,
            userInfo: [urlKey: downloadURL]
        )
        return true
    }

    static func downloadURL(from shareLink: URL) -> URL? {
        guard
            shareLink.scheme?.lowercased() == "sidekick",
            shareLink.host?.lowercased() == "import",
            let encoded = shareLink.pathComponents.dropFirst().first,
            let downloadURL = decode(encoded),
            downloadURL.scheme?.lowercased() == "https"
        else { return nil }
        return downloadURL
    }

    static func consumePendingURL() -> URL? {
        defer { UserDefaults.standard.removeObject(forKey: pendingURLKey) }
        guard let value = UserDefaults.standard.string(forKey: pendingURLKey) else { return nil }
        return URL(string: value)
    }

    private static func decode(_ encoded: String) -> URL? {
        var value = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = value.count % 4
        if remainder != 0 { value += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: value),
              let string = String(data: data, encoding: .utf8) else { return nil }
        return URL(string: string)
    }
}

enum SideKickIncomingIPA {
    static let importNotification = Notification.Name("SideKick.ImportIncomingIPA")
    private static let pendingBookmarkKey = "sidekick.pending-import-ipa-bookmark"
    private static let pendingErrorKey = "sidekick.pending-import-ipa-error"

    static func handle(_ url: URL) -> Bool {
        guard url.isFileURL, url.pathExtension.lowercased() == "ipa" else { return false }
        let securityScoped = url.startAccessingSecurityScopedResource()
        defer { if securityScoped { url.stopAccessingSecurityScopedResource() } }
        if let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: pendingBookmarkKey)
            UserDefaults.standard.removeObject(forKey: pendingErrorKey)
        } else {
            UserDefaults.standard.removeObject(forKey: pendingBookmarkKey)
            UserDefaults.standard.set(IPAImportError.sourceBookmarkUnavailable.localizedDescription, forKey: pendingErrorKey)
        }
        NotificationCenter.default.post(name: importNotification, object: nil)
        return true
    }

    static func consumePendingError() -> String? {
        defer { UserDefaults.standard.removeObject(forKey: pendingErrorKey) }
        return UserDefaults.standard.string(forKey: pendingErrorKey)
    }

    static func consumePendingBookmark() -> Data? {
        defer { UserDefaults.standard.removeObject(forKey: pendingBookmarkKey) }
        return UserDefaults.standard.data(forKey: pendingBookmarkKey)
    }
}
