import Foundation
import Security

struct GitHubCredentialStore {
    private let service = "com.sidekick.github-token"

    struct Credential: Codable, Identifiable, Hashable, Sendable {
        let id: String
        var label: String
        var username: String
        var token: String
    }
    private struct Vault: Codable {
        var credentials: [Credential] = []
        var defaultID: String?
    }
    static let publicAccessID = "public"

    func all() throws -> [Credential] { try readVault().credentials }
    func defaultID() throws -> String? { try readVault().defaultID }

    func load(id: String? = nil) throws -> String? {
        if id == Self.publicAccessID { return nil }
        let vault = try readVault()
        guard let selected = id ?? vault.defaultID else { return nil }
        guard let credential = vault.credentials.first(where: { $0.id == selected }) else {
            throw GitHubCredentialError.missing
        }
        return credential.token
    }

    func save(label: String, username: String, token: String, id: String? = nil) throws {
        var vault = try readVault()
        let credential = Credential(id: id ?? UUID().uuidString, label: label, username: username, token: token)
        vault.credentials.removeAll { $0.id == credential.id }
        vault.credentials.append(credential)
        if vault.defaultID == nil && vault.credentials.count == 1 { vault.defaultID = credential.id }
        try writeVault(vault)
    }

    func setDefault(_ id: String?) throws {
        var vault = try readVault()
        vault.defaultID = id
        try writeVault(vault)
    }

    func delete(id: String) throws {
        var vault = try readVault()
        vault.credentials.removeAll { $0.id == id }
        if vault.defaultID == id { vault.defaultID = vault.credentials.first?.id }
        try writeVault(vault)
    }

    private func readVault() throws -> Vault {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return Vault() }
        guard status == errSecSuccess, let data = result as? Data else {
            throw GitHubCredentialError.keychain(status)
        }
        if let vault = try? JSONDecoder().decode(Vault.self, from: data) { return vault }
        // Preserve the original single-token entry during migration.
        guard data.first != UInt8(ascii: "{"), let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw GitHubCredentialError.keychain(errSecDecode)
        }
        let credential = Credential(id: "legacy", label: "GitHub", username: "", token: token)
        let vault = Vault(credentials: [credential], defaultID: credential.id)
        try writeVault(vault)
        return vault
    }

    private func writeVault(_ vault: Vault) throws {
        let data = try JSONEncoder().encode(vault)
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw GitHubCredentialError.keychain(addStatus) }
        } else if status != errSecSuccess { throw GitHubCredentialError.keychain(status) }
        NotificationCenter.default.post(name: .sideKickGitHubSettingsDidChange, object: nil)
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "github"]
    }
}

private enum GitHubCredentialError: LocalizedError {
    case keychain(OSStatus)
    case missing
    var errorDescription: String? {
        if case .missing = self { return "The selected GitHub token was removed. Choose another token in this app’s GitHub settings." }
        if case .keychain(let status) = self {
            return "SideKick couldn’t securely save the GitHub token (Keychain status \(status))."
        }
        return "SideKick couldn’t securely save the GitHub token."
    }
}
