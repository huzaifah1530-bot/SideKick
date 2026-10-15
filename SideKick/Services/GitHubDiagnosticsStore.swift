import Foundation

/// Structured diagnostics deliberately exclude request headers, response bodies,
/// tokens, account identifiers and arbitrary error descriptions.
actor GitHubDiagnosticsStore {
    enum Event: String, Codable, Sendable {
        case scanStarted, scanFinished, scanCancelled, checkStarted, checkFinished, checkPublished, checkSkipped, requestFinished, cacheHit
        var title: String {
            switch self {
            case .scanStarted: "Update check started"
            case .scanFinished: "Update check finished"
            case .scanCancelled: "Update check cancelled"
            case .checkStarted: "Checking app"
            case .checkFinished: "App check finished"
            case .checkPublished: "Update status shown in app"
            case .checkSkipped: "Check deferred"
            case .requestFinished: "GitHub response"
            case .cacheHit: "Using saved build history"
            }
        }
    }
    enum SkipReason: String, Codable, Sendable {
        case notConfigured, superseded, throttled, inFlight, catalogueLoading, suspended, cancelled
    }
    enum Failure: String, Codable, Sendable {
        case authorization, rateLimitOrPermission, server, invalidSource, ambiguousDownload, invalidResponse, paginationLimit, network, timeout, cancelled, unknown
        static func classify(_ error: Error) -> Failure {
            if error is CancellationError { return .cancelled }
            if let error = error as? GitHubHistoryError {
                switch error {
                case .unauthorized: return .authorization
                case .unavailable(let status): return [403, 429].contains(status) ? .rateLimitOrPermission : .server
                case .invalidSource: return .invalidSource
                case .ambiguousAsset: return .ambiguousDownload
                case .invalidResponse: return .invalidResponse
                case .paginationLimit: return .paginationLimit
                }
            }
            if let error = error as? URLError {
                return error.code == .cancelled ? .cancelled : (error.code == .timedOut ? .timeout : .network)
            }
            return .unknown
        }
        var message: String {
            switch self {
            case .authorization: "GitHub rejected authentication. Check the selected token."
            case .rateLimitOrPermission: "GitHub restricted access. Check token permissions or rate limits."
            case .server: "GitHub could not serve this request."
            case .invalidSource: "The repository or workflow configuration is invalid."
            case .ambiguousDownload: "Multiple downloads match. Set an exact asset or artifact name."
            case .invalidResponse: "The response did not contain valid build information."
            case .paginationLimit: "This source exceeded the artifact page limit."
            case .network: "The network request failed."
            case .timeout: "The network request timed out."
            case .cancelled: "The request was cancelled."
            case .unknown: "The check failed. Review the app’s update source settings."
            }
        }
    }
    struct Entry: Identifiable, Codable, Sendable {
        let id: UUID
        let date: Date
        let event: Event
        let appName: String?
        let repository: String?
        let authenticated: Bool?
        let httpStatus: Int?
        let failure: Failure?
        let count: Int?
        let result: String?
        let skip: SkipReason?
        var details: String {
            var parts = [String]()
            if let appName { parts.append(appName) }
            if let repository { parts.append(repository) }
            if let authenticated { parts.append(authenticated ? "Token supplied" : "No token supplied") }
            if let httpStatus { parts.append("HTTP \(httpStatus)") }
            if let result { parts.append(result) }
            if let skip { parts.append("Reason: \(skip.rawValue)") }
            if let count { parts.append("\(count) results") }
            if let failure { parts.append(failure.message) }
            return parts.joined(separator: " · ")
        }
    }
    struct Snapshot: Sendable {
        let entries: [Entry]
        let persistenceFailed: Bool
    }
    static let shared = GitHubDiagnosticsStore(fileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("SideKick/Diagnostics/github-checks.json"))
    private let fileURL: URL?
    private let limit: Int
    private var entries: [Entry] = []
    private var persistenceFailed = false

    init(fileURL: URL? = nil, limit: Int = 250) {
        self.fileURL = fileURL
        self.limit = max(1, min(limit, 500))
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 1024 * 1024 else { persistenceFailed = true; return }
                entries = Array(try JSONDecoder().decode([Entry].self, from: Data(contentsOf: fileURL)).suffix(self.limit))
            } catch { persistenceFailed = true }
        }
    }

    func record(_ event: Event, appName: String? = nil, repository: String? = nil,
                authenticated: Bool? = nil, httpStatus: Int? = nil, failure: Failure? = nil,
                count: Int? = nil, state: GitHubCheckState? = nil, skip: SkipReason? = nil) {
        entries.append(Entry(id: UUID(), date: .now, event: event,
            appName: appName.map(Self.safeName), repository: Self.safeRepository(repository),
            authenticated: authenticated, httpStatus: httpStatus, failure: failure,
            count: count, result: state?.title, skip: skip))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        persist()
    }

    func snapshot() -> Snapshot { Snapshot(entries: Array(entries.reversed()), persistenceFailed: persistenceFailed) }
    func clear() { entries.removeAll(); persist() }

    nonisolated static func export(_ entries: [Entry]) -> String {
        let formatter = ISO8601DateFormatter()
        return (["SideKick GitHub update diagnostics"] + entries.map {
            "\(formatter.string(from: $0.date)) | \($0.event.title) | \($0.details)"
        }).joined(separator: "\n")
    }

    private func persist() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
            persistenceFailed = false
        } catch { persistenceFailed = true }
    }

    nonisolated private static func safeName(_ value: String) -> String {
        String(value.prefix(160)).replacingOccurrences(of: "[\\p{Cc}\\p{Cf}]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "(?:gh[pousr]_|github_pat_)[A-Za-z0-9_]+", with: "[redacted]", options: .regularExpression)
    }

    nonisolated private static func safeRepository(_ value: String?) -> String? {
        guard let value, let url = URL(string: value), url.host?.lowercased() == "github.com" else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count >= 2, parts.prefix(2).allSatisfy({ $0.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil }) else { return nil }
        return safeName(parts.prefix(2).joined(separator: "/").lowercased())
    }
}
