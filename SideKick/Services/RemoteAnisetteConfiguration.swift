import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The recommended Anisette server list kept in SideKick's GitHub repository
/// (config/anisette-servers.json). Maintainers replace a patched server there,
/// and users pick it up from Settings without waiting for an app release.
struct RemoteAnisetteServerList: Decodable, Equatable, Sendable {
    let schemaVersion: Int
    let updatedAt: Date?
    let recommended: String
    let servers: [RemoteAnisetteServer]

    var recommendedServer: RemoteAnisetteServer? { servers.first { $0.id == recommended } }
}

struct RemoteAnisetteServer: Decodable, Equatable, Sendable {
    let id: String
    let name: String
    let url: String
    let headers: [String: String]

    /// Request headers SideKick's Anisette client can send. Others would be
    /// silently dropped, so a list that needs them is rejected instead.
    static let supportedHeaders: Set<String> = ["x-mme-client-info", "user-agent"]

    var clientInfo: String { header("X-Mme-Client-Info") }
    var userAgent: String { header("User-Agent") }

    private func header(_ name: String) -> String {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
    }
}

struct RemoteAnisetteSelection: Equatable, Sendable {
    let server: RemoteAnisetteServer
    let serverURL: URL
    /// When the file last changed in the repository, or the file's own date.
    let lastUpdated: Date?
}

enum RemoteAnisetteConfigurationError: LocalizedError, Equatable {
    case unavailable(Int), invalidFile, unsupportedSchema, noRecommendedServer, unsafeServer(String), unsupportedHeader(String), missingHeaders(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let code): "SideKick couldn’t download the server list from GitHub (HTTP \(code)). Check your connection and try again."
        case .invalidFile: "The server list on GitHub isn’t valid. Your current Anisette settings weren’t changed."
        case .unsupportedSchema: "The server list on GitHub needs a newer SideKick. Update SideKick, then try again."
        case .noRecommendedServer: "The server list on GitHub doesn’t name a recommended server. Your current settings weren’t changed."
        case .unsafeServer(let name): "\(name) doesn’t use a secure HTTPS address, so SideKick won’t use it."
        case .unsupportedHeader(let header): "The recommended server needs the \(header) header, which this version of SideKick can’t send. Update SideKick, then try again."
        case .missingHeaders(let name): "\(name) is missing its client information or user agent headers. Your current settings weren’t changed."
        }
    }
}

enum RemoteAnisetteConfiguration {
    static let repositoryPath = "config/anisette-servers.json"
    /// HEAD follows the repository's default branch.
    static let fileURL = URL(string: "https://raw.githubusercontent.com/huzaifah1530-bot/SideKick/HEAD/" + repositoryPath)!
    static let historyURL = URL(string: "https://api.github.com/repos/huzaifah1530-bot/SideKick/commits?path=" + repositoryPath + "&per_page=1")!
    static let maximumSize = 64 * 1024

    static func decode(_ data: Data) throws -> RemoteAnisetteServerList {
        guard data.count <= maximumSize else { throw RemoteAnisetteConfigurationError.invalidFile }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            guard let date = parseDate(value) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid date"))
            }
            return date
        }
        // Read the version first so a future format reports the right error.
        struct Version: Decodable { let schemaVersion: Int }
        guard let version = try? decoder.decode(Version.self, from: data) else { throw RemoteAnisetteConfigurationError.invalidFile }
        guard version.schemaVersion == 1 else { throw RemoteAnisetteConfigurationError.unsupportedSchema }
        do { return try decoder.decode(RemoteAnisetteServerList.self, from: data) }
        catch { throw RemoteAnisetteConfigurationError.invalidFile }
    }

    /// Checks the recommended server before anything is saved.
    static func validatedSelection(from list: RemoteAnisetteServerList, lastUpdated: Date?) throws -> RemoteAnisetteSelection {
        guard let server = list.recommendedServer else { throw RemoteAnisetteConfigurationError.noRecommendedServer }
        guard let url = try? AnisetteConfiguration.validatedServer(server.url), url.scheme?.lowercased() == "https" else {
            // Remote lists never point at localhost or plain HTTP.
            throw RemoteAnisetteConfigurationError.unsafeServer(server.name)
        }
        for key in server.headers.keys.sorted() where !RemoteAnisetteServer.supportedHeaders.contains(key.lowercased()) {
            throw RemoteAnisetteConfigurationError.unsupportedHeader(key)
        }
        guard (try? AnisetteConfiguration.validatedHeader(server.clientInfo)).map({ !$0.isEmpty }) == true,
              (try? AnisetteConfiguration.validatedHeader(server.userAgent)).map({ !$0.isEmpty }) == true else {
            throw RemoteAnisetteConfigurationError.missingHeaders(server.name)
        }
        return RemoteAnisetteSelection(server: server, serverURL: url, lastUpdated: lastUpdated ?? list.updatedAt)
    }

    static func parseDate(_ value: String) -> Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

/// Downloads the server list from the repository source, not GitHub Releases.
struct RemoteAnisetteConfigurationClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport

    init(transport: @escaping Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RemoteAnisetteConfigurationError.invalidFile }
        return (data, http)
    }) { self.transport = transport }

    func fetchRecommended() async throws -> RemoteAnisetteSelection {
        let (data, response) = try await transport(request(RemoteAnisetteConfiguration.fileURL, accept: "application/json"))
        guard (200..<300).contains(response.statusCode) else { throw RemoteAnisetteConfigurationError.unavailable(response.statusCode) }
        let list = try RemoteAnisetteConfiguration.decode(data)
        let committed = await lastCommitDate()
        return try RemoteAnisetteConfiguration.validatedSelection(from: list, lastUpdated: committed)
    }

    /// The commit date is authoritative even if a maintainer forgets to edit `updatedAt`.
    /// It is optional: rate limits must not block switching servers.
    private func lastCommitDate() async -> Date? {
        struct Commit: Decodable {
            struct Details: Decodable { struct Person: Decodable { let date: String }; let committer: Person }
            let commit: Details
        }
        guard let result = try? await transport(request(RemoteAnisetteConfiguration.historyURL, accept: "application/vnd.github+json")),
              (200..<300).contains(result.1.statusCode), result.0.count <= 512 * 1024,
              let commit = try? JSONDecoder().decode([Commit].self, from: result.0).first else { return nil }
        return RemoteAnisetteConfiguration.parseDate(commit.commit.committer.date)
    }

    private func request(_ url: URL, accept: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("SideKick", forHTTPHeaderField: "User-Agent")
        return request
    }
}
