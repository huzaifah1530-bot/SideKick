import Foundation

enum LiveContainerStorageKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case privateDocuments, sharedDirectory, snapshot
    var id: String { rawValue }
    var title: String {
        switch self {
        case .privateDocuments: "Private apps"
        case .sharedDirectory: "Shared apps"
        case .snapshot: "Exported snapshot"
        }
    }
    /// Where this folder lives inside LiveContainer, shown when linking it.
    var location: String {
        switch self {
        case .privateDocuments: "On My iPhone › LiveContainer › Applications"
        case .sharedDirectory: "the LiveContainer/Applications folder every installation shares"
        case .snapshot: "a copied Applications folder, read only"
        }
    }
}

/// LiveContainer installs side by side under these schemes (LiveContainer, LiveContainer2…).
enum LiveContainerInstallation {
    static let knownSchemes = ["livecontainer", "livecontainer2", "livecontainer3"]

    static func displayName(for scheme: String) -> String {
        guard let index = knownSchemes.firstIndex(of: scheme.lowercased()) else { return scheme }
        return index == 0 ? "LiveContainer" : "LiveContainer \(index + 1)"
    }

    /// Default connection name for a scheme and folder type.
    static func connectionName(scheme: String, storageKind: LiveContainerStorageKind) -> String {
        switch storageKind {
        // Shared apps belong to every installation, so the name doesn't single one out.
        case .sharedDirectory: "LiveContainer Shared Apps"
        case .snapshot: "\(displayName(for: scheme)) Snapshot"
        case .privateDocuments: displayName(for: scheme)
        }
    }
}

struct LiveContainerConnection: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    var name: String
    var scheme: String
    var storageKind: LiveContainerStorageKind
    var bookmark: Data?
    var lastSuccessfulScan: Date?
    var error: String?
    var warnings: [String] = []
    var isConnected: Bool { bookmark != nil }
}

struct LiveContainerGuest: Codable, Identifiable, Sendable, Equatable {
    let connectionID: UUID
    let folder: String
    var name: String
    var bundleIdentifier: String
    var version: String
    var build: String
    var iconData: Data?
    var lastSeen: Date
    var isAvailable: Bool = true
    var observation: String? = nil
    var warning: String?
    var executableIdentity: String? = nil
    /// LiveContainer's data folder for this guest (`LCDataUUID`), used to find the
    /// installation already running it.
    var dataFolder: String? = nil
    var id: String { Self.identifier(connectionID: connectionID, folder: folder) }

    static func identifier(connectionID: UUID, folder: String) -> String {
        "livecontainer:\(connectionID.uuidString):\(Data(folder.utf8).base64EncodedString())"
    }

    var updateTarget: GitHubUpdateTarget {
        GitHubUpdateTarget(id: id, name: name, version: version, kind: .liveContainer, observation: observation ?? [version, build].joined(separator: "|"))
    }
}

struct LiveContainerState: Codable, Sendable {
    var schemaVersion = 1
    var connections: [LiveContainerConnection] = []
    var apps: [LiveContainerGuest] = []
    var pendingForgetGuestIDs: [UUID: [String]] = [:]

    private enum CodingKeys: String, CodingKey { case schemaVersion, connections, apps, pendingForgetGuestIDs }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        connections = try values.decode([LiveContainerConnection].self, forKey: .connections)
        apps = try values.decode([LiveContainerGuest].self, forKey: .apps)
        pendingForgetGuestIDs = try values.decodeIfPresent([UUID: [String]].self, forKey: .pendingForgetGuestIDs) ?? [:]
    }
}

enum LiveContainerImportPolicy {
    static func matches(_ ipa: ImportedIPA, guest: LiveContainerGuest, connection: LiveContainerConnection) -> Bool {
        // An older guest can have identical version labels while the share sheet
        // is still open. Wait for the downloaded binary instead of consuming intent.
        if let expected = ipa.executableIdentity, let observed = guest.executableIdentity, expected != observed { return false }
        return guest.connectionID == connection.id && connection.isConnected && connection.error == nil &&
            connection.storageKind != .snapshot && guest.isAvailable &&
            guest.bundleIdentifier.caseInsensitiveCompare(ipa.bundleIdentifier) == .orderedSame &&
            guest.version == ipa.version && ipa.buildVersion == guest.build
    }

    static func verifiesBuild(_ ipa: ImportedIPA, guest: LiveContainerGuest) -> Bool {
        guard let identity = ipa.executableIdentity, !identity.isEmpty else { return false }
        return identity == guest.executableIdentity
    }
}

enum LiveContainerImportError: LocalizedError {
    case guestMismatch, missingSource
    var errorDescription: String? {
        switch self {
        case .guestMismatch: "This guest does not match the imported IPA, or its folder is unavailable. Import the IPA in LiveContainer and rescan."
        case .missingSource: "This IPA has no complete GitHub download record. Configure its update source in the guest’s settings."
        }
    }
}

struct LiveContainerScan: Sendable {
    var apps: [LiveContainerGuest] = []
    var warnings: [String] = []
    var failedFolders: [String] = []
}

enum LiveContainerError: LocalizedError {
    case invalidDirectory, accessRevoked, invalidMetadata(String), unsupportedSchema, busy, disconnected, guestMissing, invalidScheme, alreadyLinked(String)
    var errorDescription: String? {
        switch self {
        case .invalidDirectory: "Choose LiveContainer’s actual Applications folder in Files. Private App Group storage is unavailable unless a file provider exposes it."
        case .accessRevoked: "SideKick cannot access this directory. Reconnect and select Applications again."
        case .invalidMetadata(let reason): reason
        case .unsupportedSchema: "This LiveContainer catalogue was saved by a newer SideKick version. Update SideKick before changing it."
        case .busy: "A scan is already running for this connection."
        case .disconnected: "Reconnect this LiveContainer directory first."
        case .guestMissing: "This guest app is no longer available in the linked directory. Rescan or open LiveContainer to check it."
        case .invalidScheme: "Enter a LiveContainer installation’s URL scheme, without ://. Web and SideKick schemes cannot be used."
        case .alreadyLinked(let name): "This folder is already linked as “\(name)”. Apps in it are listed once, so you don’t need to add it again."
        }
    }
}

enum LiveContainerLaunch {
    static func url(scheme: String, folder: String? = nil) throws -> URL {
        let scheme = scheme.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard scheme.range(of: "^[a-z][a-z0-9+.-]*$", options: .regularExpression) != nil,
              !["http", "https", "file", "data", "javascript", "sidekick", "sidestore"].contains(scheme) else {
            throw LiveContainerError.invalidScheme
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = "livecontainer-launch"
        if let folder {
            guard !folder.isEmpty, !folder.contains("/"), !folder.contains("\\"),
                  folder.hasSuffix(".app"), folder != ".app" else { throw LiveContainerError.guestMissing }
            components.queryItems = [URLQueryItem(name: "bundle-name", value: folder)]
        } else {
            components.queryItems = [URLQueryItem(name: "bundle-name", value: "ui")]
        }
        guard let url = components.url else { throw LiveContainerError.invalidScheme }
        return url
    }
}
