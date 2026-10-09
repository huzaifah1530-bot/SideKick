import Foundation
import Security

struct GitHubCredentialStore {
    private let service = "com.sidekick.github-token"

    func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw GitHubCredentialError.keychain(status)
        }
        return token
    }

    func save(_ token: String) throws {
        let data = Data(token.utf8)
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw GitHubCredentialError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw GitHubCredentialError.keychain(status)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw GitHubCredentialError.keychain(status) }
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "github"]
    }
}

private enum GitHubCredentialError: LocalizedError {
    case keychain(OSStatus)
    var errorDescription: String? {
        if case .keychain(let status) = self {
            return "SideKick couldn’t securely save the GitHub token (Keychain status \(status))."
        }
        return "SideKick couldn’t securely save the GitHub token."
    }
}
