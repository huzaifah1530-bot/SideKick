#if canImport(Security)
import Foundation
import Security

// Runs as the temporarily installed native helper, outside LiveContainer's hooks.
// No credential values are written to Files, logs, Info.plist or UserDefaults.
struct SideKickCredentialStore: AppCredentialStore {
    private let allowed: [String] = [kSecClass, kSecAttrAccount, kSecAttrService, kSecAttrServer,
        kSecAttrSecurityDomain, kSecAttrPath, kSecAttrPort, kSecAttrProtocol, kSecAttrAuthenticationType,
        kSecAttrAccessible, kSecAttrSynchronizable, kSecAttrLabel, kSecAttrDescription,
        kSecAttrComment, kSecAttrCreator, kSecAttrType, kSecAttrIsInvisible,
        kSecAttrIsNegative, kSecAttrGeneric].map { $0 as String }

    func readSource(groups: [String]) throws -> [AppCredentialItem] {
        var result: [AppCredentialItem] = []
        var bytes = 0
        for group in groups {
            for kind in [kSecClassKey, kSecClassCertificate, kSecClassIdentity] {
                var query = base(kind: kind, group: group)
                query[kSecMatchLimit as String] = kSecMatchLimitOne
                let status = SecItemCopyMatching(query as CFDictionary, nil)
                if status == errSecMissingEntitlement { throw AppCredentialTransferError.permissions }
                guard status == errSecItemNotFound else { throw AppCredentialTransferError.protectedItems }
            }
            for kind in [kSecClassGenericPassword, kSecClassInternetPassword] {
                var query = base(kind: kind, group: group)
                query[kSecMatchLimit as String] = kSecMatchLimitAll
                query[kSecReturnAttributes as String] = true
                query[kSecReturnData as String] = true
                var value: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &value)
                if status == errSecMissingEntitlement { throw AppCredentialTransferError.permissions }
                if status == errSecItemNotFound { continue }
                guard status == errSecSuccess, let rows = value as? [[String: Any]] else {
                    throw AppCredentialTransferError.protectedItems
                }
                for row in rows {
                    guard row[kSecAttrAccessControl as String] == nil,
                          let secret = row[kSecValueData as String] as? Data else { throw AppCredentialTransferError.protectedItems }
                    bytes += secret.count
                    guard result.count < 10_000, bytes <= 16 * 1024 * 1024 else { throw AppCredentialTransferError.tooLarge }
                    var attributes = row.filter { allowed.contains($0.key) }
                    attributes[kSecClass as String] = kind
                    result.append(AppCredentialItem(attributes: attributes, secret: secret))
                }
            }
        }
        return result
    }

    private func base(kind: CFString, group: String) -> [String: Any] {
        [kSecClass as String: kind, kSecAttrAccessGroup as String: group,
         kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
         kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }

    func existing(_ item: AppCredentialItem, destination: AppCredentialDestination) throws -> AppCredentialItem? {
        let primary = [kSecClass, kSecAttrAccount, kSecAttrService, kSecAttrServer,
            kSecAttrSecurityDomain, kSecAttrPath, kSecAttrPort, kSecAttrProtocol,
            kSecAttrAuthenticationType, kSecAttrSynchronizable].map { $0 as String }
        var query = item.attributes.filter { primary.contains($0.key) }
        query[kSecAttrAccessGroup as String] = destination.group
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let row = value as? [String: Any],
              row["alis"] as? String == destination.container else { throw AppCredentialTransferError.conflict }
        return try project(row, kind: item.attributes[kSecClass as String])
    }

    func insert(_ item: AppCredentialItem, destination: AppCredentialDestination) throws -> Data {
        var attributes = item.attributes
        attributes[kSecAttrAccessGroup as String] = destination.group
        attributes["alis"] = destination.container // LiveContainer's own cleanup ownership marker.
        attributes[kSecValueData as String] = item.secret
        attributes[kSecReturnPersistentRef as String] = true
        var value: CFTypeRef?
        let status = SecItemAdd(attributes as CFDictionary, &value)
        guard status == errSecSuccess, let reference = value as? Data else { throw AppCredentialTransferError.verification }
        return reference
    }

    func readInserted(reference: Data, original: AppCredentialItem) throws -> AppCredentialItem {
        let query: [String: Any] = [kSecValuePersistentRef as String: reference,
            kSecReturnAttributes as String: true, kSecReturnData as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let row = value as? [String: Any] else { throw AppCredentialTransferError.verification }
        return try project(row, kind: original.attributes[kSecClass as String])
    }

    private func project(_ row: [String: Any], kind: Any?) throws -> AppCredentialItem {
        guard let secret = row[kSecValueData as String] as? Data, let kind else { throw AppCredentialTransferError.verification }
        var attributes = row.filter { allowed.contains($0.key) }
        attributes[kSecClass as String] = kind
        return AppCredentialItem(attributes: attributes, secret: secret)
    }

    func removeInserted(reference: Data) throws {
        let status = SecItemDelete([kSecValuePersistentRef as String: reference] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AppCredentialTransferError.verification }
    }
}


#endif
