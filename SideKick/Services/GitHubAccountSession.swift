import Foundation

/// The SideKick GitHub App registration. Fill these in after registering the app on github.com
/// (Settings → Developer settings → GitHub Apps). Neither value is secret.
enum GitHubAppConfiguration {
    /// "Client ID" on the app's settings page (starts with "Iv").
    static let clientID = "Iv23liNJAemA3qF2Owxw"
    /// The app's URL name, as in github.com/apps/<slug>. Used for "Choose Repositories".
    static let slug = "sidekick-huzaifah1530"

    static var isConfigured: Bool { !clientID.isEmpty }
    static var installURL: URL? { slug.isEmpty ? nil : URL(string: "https://github.com/apps/\(slug)/installations/new") }
}

/// Sign in with GitHub using the device flow: no password or client secret passes through
/// SideKick. The resulting user token is read-only because the app only asks for read access.
/// It's stored in the same Keychain vault as personal tokens, so every token picker offers it.
enum GitHubAccountSession {
    static let credentialID = "github-account"

    struct DeviceCode: Sendable {
        let deviceCode: String
        let userCode: String
        let verificationURL: URL
        let expiresAt: Date
        let interval: TimeInterval
    }

    enum SessionError: LocalizedError {
        case notConfigured, denied, expired, invalidResponse, server(String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: "GitHub sign-in isn’t set up in this build yet."
            case .denied: "GitHub sign-in was canceled."
            case .expired: "The sign-in code expired. Start again to get a new one."
            case .invalidResponse: "GitHub returned an unexpected response. Try again."
            case .server(let message): message
            }
        }
    }

    static var isSignedIn: Bool {
        (try? GitHubCredentialStore().all().contains { $0.id == credentialID }) ?? false
    }

    static var account: GitHubCredentialStore.Credential? {
        try? GitHubCredentialStore().all().first { $0.id == credentialID }
    }

    // MARK: Device flow

    static func requestCode() async throws -> DeviceCode {
        guard GitHubAppConfiguration.isConfigured else { throw SessionError.notConfigured }
        struct Response: Decodable {
            let device_code: String
            let user_code: String
            let verification_uri: String
            let expires_in: Double
            let interval: Double?
        }
        let response: Response = try await post("https://github.com/login/device/code",
                                                 ["client_id": GitHubAppConfiguration.clientID])
        guard let url = URL(string: response.verification_uri) else { throw SessionError.invalidResponse }
        return DeviceCode(deviceCode: response.device_code, userCode: response.user_code, verificationURL: url,
                          expiresAt: .now.addingTimeInterval(response.expires_in), interval: max(response.interval ?? 5, 5))
    }

    /// Polls until the user approves in Safari, then saves the account. Honors GitHub's slow_down.
    static func completeSignIn(_ code: DeviceCode) async throws -> String {
        var interval = code.interval
        while Date.now < code.expiresAt {
            try await Task.sleep(for: .seconds(interval))
            let result: TokenResponse = try await post("https://github.com/login/oauth/access_token", [
                "client_id": GitHubAppConfiguration.clientID,
                "device_code": code.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            switch result.error {
            case nil:
                return try await store(result)
            case "authorization_pending":
                continue
            case "slow_down":
                interval = max(interval + 5, result.interval ?? interval)
            case "expired_token":
                throw SessionError.expired
            case "access_denied":
                throw SessionError.denied
            default:
                throw SessionError.server(result.error_description ?? "GitHub sign-in failed.")
            }
        }
        throw SessionError.expired
    }

    // MARK: Refresh

    /// User tokens last 8 hours. Renew when less than an hour remains; silently keep the old
    /// token if GitHub can't be reached. Refresh needs no client secret for device-flow tokens.
    @discardableResult
    static func refreshIfNeeded() async -> Bool {
        guard GitHubAppConfiguration.isConfigured, let account,
              let refreshToken = account.refreshToken else { return false }
        if let expiresAt = account.expiresAt, expiresAt > .now.addingTimeInterval(3_600) { return true }
        do {
            let result: TokenResponse = try await post("https://github.com/login/oauth/access_token", [
                "client_id": GitHubAppConfiguration.clientID,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
            ])
            guard result.error == nil else {
                debugLog("[SideKick] GitHub account refresh failed: \(result.error ?? "")")
                return false
            }
            _ = try await store(result, username: account.username)
            return true
        } catch {
            debugLog("[SideKick] GitHub account refresh failed: \(error.localizedDescription)")
            return false
        }
    }

    static func signOut() throws {
        try GitHubCredentialStore().delete(id: credentialID)
    }

    // MARK: Helpers

    private struct TokenResponse: Decodable {
        let access_token: String?
        let expires_in: Double?
        let refresh_token: String?
        let error: String?
        let error_description: String?
        let interval: Double?
    }

    private static func store(_ response: TokenResponse, username: String? = nil) async throws -> String {
        guard let token = response.access_token else { throw SessionError.invalidResponse }
        let login: String
        if let username, !username.isEmpty { login = username }
        else { login = (try? await GitHubUpdateService().validateToken(token)) ?? "" }
        let store = GitHubCredentialStore()
        let hadDefault = (try? store.defaultID()) != nil
        try store.save(
            label: "GitHub Account",
            username: login,
            token: token,
            id: credentialID,
            refreshToken: response.refresh_token,
            expiresAt: response.expires_in.map { Date.now.addingTimeInterval($0) }
        )
        if !hadDefault { try? store.setDefault(credentialID) }
        return login
    }

    private static func post<T: Decodable>(_ url: String, _ parameters: [String: String]) async throws -> T {
        guard let endpoint = URL(string: url) else { throw SessionError.invalidResponse }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("SideKick iOS app", forHTTPHeaderField: "User-Agent")
        var components = URLComponents()
        components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SessionError.invalidResponse
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw SessionError.invalidResponse }
    }
}
