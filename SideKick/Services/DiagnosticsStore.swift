import Foundation

/// Only enums, UUIDs, dates and numbers cross this boundary. Never accept an
/// error description, request, URL, header, response body or account identifier.
final class DiagnosticsStore: @unchecked Sendable {
    enum Operation: String, Codable, Sendable {
        case addAccount, restoreAccount, install, refresh, resign, connection, github, lifecycle
        var title: String {
            switch self {
            case .addAccount: "Add Apple ID"
            case .restoreAccount: "Restore account"
            case .install: "Install app"
            case .refresh: "Refresh app"
            case .resign: "Sign app again"
            case .connection: "Local connection"
            case .github: "GitHub updates"
            case .lifecycle: "App activity"
            }
        }
    }
    enum Stage: String, Codable, Sendable {
        case authentication, anisette, authInit, authComplete, authTokens
        case twoFactor, twoFactorVerify, developerTeam, session
        case signing, installation, refresh, localConnection, github, lifecycle

        var title: String {
            switch self {
            case .authentication: "Apple sign-in"
            case .anisette: "Anisette generation"
            case .authInit: "Apple handshake"
            case .authComplete: "Apple authentication response"
            case .authTokens: "Apple session tokens"
            case .twoFactor: "Two-factor verification"
            case .twoFactorVerify: "Verification response"
            case .developerTeam: "Developer team"
            case .session: "Saved session"
            case .signing: "Signing"
            case .installation: "Installation"
            case .refresh: "Refresh"
            case .localConnection: "Local connection"
            case .github: "GitHub discovery"
            case .lifecycle: "Foreground and background"
            }
        }

        var help: String {
            switch self {
            case .anisette: return "Check the selected Anisette provider and its matching client configuration."
            case .authInit, .authComplete, .authentication: return "Apple sign-in failed. Keep the stage and codes when reporting this; avoid repeated attempts."
            case .twoFactor, .twoFactorVerify: return "Check verification on a trusted Apple device. Wait if Apple limits attempts."
            case .authTokens, .session: return "Apple session creation or secure storage failed."
            case .developerTeam: return "Apple authentication reached developer team selection."
            case .localConnection: return "Check pairing, the selected local connection and VPN availability."
            case .signing: return "Check the selected account, certificate and provisioning state."
            case .installation, .refresh: return "Check the preceding signing and connection events for this operation."
            case .github: return "See GitHub Update Logs for per-app discovery details."
            case .lifecycle: return "Foreground resumes pending checks; background pauses them."
            }
        }
    }
    enum Event: String, Codable, Sendable { case started, succeeded, failed, response, paused, resumed }
    enum ErrorKind: String, Codable, Sendable { case network, cocoa, keychain, apple, other }
    struct Entry: Identifiable, Codable, Sendable {
        let id: UUID
        let date: Date
        let operationID: UUID
        let operation: Operation
        let stage: Stage
        let event: Event
        let errorKind: ErrorKind?
        let code: Int?
        let httpStatus: Int?
        let challengeStatus: Int?
        var details: String {
            [errorKind?.rawValue, code.map { "Code \($0)" }, httpStatus.map { "HTTP \($0)" }, challengeStatus.map { "Apple status \($0)" }]
                .compactMap { $0 }.joined(separator: " · ")
        }
    }
    struct Snapshot: Sendable { let entries: [Entry]; let persistenceFailed: Bool }
    @TaskLocal static var operationID: UUID?
    @TaskLocal static var operation: Operation = .lifecycle
    static let shared = DiagnosticsStore(fileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("SideKick/Diagnostics/operations.json"))
    private let lock = NSLock()
    private let fileURL: URL?
    private let limit: Int
    private var entries: [Entry] = []
    private var persistenceFailed = false

    init(fileURL: URL? = nil, limit: Int = 500) {
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

    func record(_ event: Event, operation: Operation, stage: Stage, operationID: UUID,
                errorKind: ErrorKind? = nil, code: Int? = nil, httpStatus: Int? = nil, challengeStatus: Int? = nil) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(Entry(id: UUID(), date: .now, operationID: operationID, operation: operation,
            stage: stage, event: event, errorKind: errorKind, code: code,
            httpStatus: httpStatus.flatMap { (100...599).contains($0) ? $0 : nil }, challengeStatus: challengeStatus))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        persist()
    }

    func failure(_ error: Error, operation: Operation, stage: Stage, operationID: UUID) {
        // Preserve bounded numeric underlying errors, never userInfo text or domains
        // supplied by a server. Those may contain credentials or response payloads.
        var current = error as NSError
        for _ in 0..<4 {
            let kind: ErrorKind
            switch current.domain {
            case NSURLErrorDomain: kind = .network
            case NSCocoaErrorDomain: kind = .cocoa
            case NSOSStatusErrorDomain: kind = .keychain
            default: kind = .other
            }
            record(.failed, operation: operation, stage: stage, operationID: operationID, errorKind: kind, code: current.code)
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
    }

    @MainActor static func perform<T>(_ operation: Operation, stage: Stage,
        body: () async throws -> T) async rethrows -> T {
        let id = operationID ?? UUID()
        return try await $operationID.withValue(id) {
            try await $operation.withValue(operation) {
                shared.record(.started, operation: operation, stage: stage, operationID: id)
                do {
                    let result = try await body()
                    shared.record(.succeeded, operation: operation, stage: stage, operationID: id)
                    return result
                } catch {
                    shared.failure(error, operation: operation, stage: stage, operationID: id)
                    throw error
                }
            }
        }
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(entries: Array(entries.reversed()), persistenceFailed: persistenceFailed)
    }
    func clear() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
        persist()
    }
    static func export(_ entries: [Entry]) -> String {
        let formatter = ISO8601DateFormatter()
        return (["SideKick operation diagnostics"] + entries.map {
            "\(formatter.string(from: $0.date)) | \($0.operationID.uuidString) | \($0.operation.rawValue) | \($0.stage.rawValue) | \($0.event.rawValue) | \($0.details)"
        }).joined(separator: "\n")
    }
    private func persist() {
        guard var fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            #if os(iOS)
            try JSONEncoder().encode(entries).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
            #endif
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try fileURL.setResourceValues(values)
            persistenceFailed = false
        } catch { persistenceFailed = true }
    }
}
