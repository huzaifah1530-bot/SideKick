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
            return "Buzzheavier accepted the upload but returned an unrecognized link."
        case .uploadFailed(let status):
            return "Buzzheavier couldn’t upload this IPA (HTTP \(status)). Try again later."
        case .downloadFailed(let status):
            return "The file host couldn’t provide this IPA (HTTP \(status)). Check the link and try again."
        case .invalidShareLink:
            return "This SideKick share link is incomplete or invalid."
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
            let shareURL = URL(string: "https://buzzheavier.com/d/\(fileID)")
        else {
            throw AppSharingError.invalidUploadResponse
        }
        return shareURL
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
