import Foundation

enum AnisetteConfiguration {
    static let windowsServer = "https://win.ani.sidestore.io"
    static let windowsClientInfo = "<PC> <Windows;6.2(0,0);9200> <com.apple.AuthKit/1 (com.apple.iTunes/12.12.4.1)>"
    static let windowsUserAgent = "akd/1.0 CFNetwork/808.1.4"

    static func validatedServer(_ value: String) throws -> URL {
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil,
              url.scheme?.lowercased() == "https" || (url.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())) else {
            throw ValidationError.server
        }
        return url
    }

    static func validatedHeader(_ value: String) throws -> String {
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ValidationError.header
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func shouldOfferWindowsDefault(persisted: [String: Any], hasConfigFile: Bool, hasSavedServers: Bool) -> Bool {
        let explicitKeys = ["useOnDeviceAnisette", "menuAnisetteURL", "menuAnisetteList", "isAnisetteOfflineMode", "disableAnisetteRotation", "sidekick.anisette.defaults.v1"]
        return !hasConfigFile && !hasSavedServers
            && !persisted.keys.contains(where: { $0.hasPrefix("customAnisette") })
            && !explicitKeys.contains(where: { persisted[$0] != nil })
    }

    enum ValidationError: LocalizedError {
        case server, header
        var errorDescription: String? {
            switch self {
            case .server: return "Enter an HTTPS server URL without a username, password, fragment, or control characters. HTTP is supported for localhost."
            case .header: return "Client information and user agent cannot contain line breaks or control characters."
            }
        }
    }
}
