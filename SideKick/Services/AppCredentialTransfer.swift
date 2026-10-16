import Foundation
import CoreFoundation

enum AppCredentialTransferError: LocalizedError {
    case configuration, permissions, protectedItems, conflict, verification, tooLarge
    var errorDescription: String? {
        switch self {
        case .configuration: "Close the guest in LiveContainer. Set the exported SideKickData folder as its default container, enable Isolate App Group, and connect LiveContainer’s Applications folder in SideKick."
        case .permissions: "Login transfer needs the native app and LiveContainer signed by the same team. Update or reinstall both through this version of SideKick to save their signing permissions, then try again. Keep their app data."
        case .protectedItems: "Some credentials are protected or use keys this transfer cannot copy. Your native app and its login are still needed."
        case .conflict: "The destination already contains different login data. Nothing has been overwritten. Use a fresh LiveContainer data container before transferring."
        case .verification: "The copied login could not be verified. Keep the native app and retry the transfer."
        case .tooLarge: "This app has too much Keychain data for a safe login transfer. Keep the native app."
        }
    }
}

// Contains metadata only. Credential bytes never enter the transfer folder or defaults.
struct AppCredentialDestination: Codable, Equatable {
    let container: String
    let group: String

    static func read(folder: URL, appID: String, team: String) throws -> Self {
        let info = try metadata(folder.appendingPathComponent("LCContainerInfo.plist"))
        guard info["appIdentifier"] as? String == appID,
              info["isolateAppGroup"] as? Bool == true,
              let number = info["keychainGroupId"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.intValue), (0...127).contains(number.intValue),
              team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
              folder.lastPathComponent.hasPrefix("SideKickData-") else { throw AppCredentialTransferError.configuration }
        let suffix = number.intValue == 0 ? "" : ".\(number.intValue)"
        return Self(container: folder.lastPathComponent, group: team + ".com.kdt.livecontainer.shared" + suffix)
    }

    static func metadata(_ url: URL) throws -> [String: Any] {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true,
              let size = values.fileSize, size <= 1024 * 1024 else { throw AppCredentialTransferError.configuration }
        let data = try Data(contentsOf: url)
        guard data.count <= 1024 * 1024,
              let dict = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw AppCredentialTransferError.configuration
        }
        return dict
    }
}

struct AppCredentialItem {
    let attributes: [String: Any]
    let secret: Data
}

protocol AppCredentialStore {
    // Must reject protected/unsupported items before returning any credentials.
    func readSource(groups: [String]) throws -> [AppCredentialItem]
    func existing(_ item: AppCredentialItem, destination: AppCredentialDestination) throws -> AppCredentialItem?
    func insert(_ item: AppCredentialItem, destination: AppCredentialDestination) throws -> Data
    func readInserted(reference: Data, original: AppCredentialItem) throws -> AppCredentialItem
    func removeInserted(reference: Data) throws
}

enum AppCredentialTransfer {
    static func copy(groups: [String], destination: AppCredentialDestination, store: any AppCredentialStore) throws {
        guard !groups.isEmpty, groups.count <= 64, Set(groups).count == groups.count,
              !groups.contains(destination.group), groups.allSatisfy({ !$0.isEmpty && !$0.contains("*") }) else {
            throw AppCredentialTransferError.permissions
        }
        let items = try store.readSource(groups: groups)
        guard items.count <= 10_000, items.reduce(0, { $0 + $1.secret.count }) <= 16 * 1024 * 1024 else {
            throw AppCredentialTransferError.tooLarge
        }
        // Check every pre-existing destination before the first write.
        for item in items {
            if let existing = try store.existing(item, destination: destination), !equal(item, existing) {
                throw AppCredentialTransferError.conflict
            }
        }
        var inserted: [Data] = []
        do {
            for item in items {
                if let existing = try store.existing(item, destination: destination) {
                    guard equal(item, existing) else { throw AppCredentialTransferError.conflict }
                    continue
                }
                let reference = try store.insert(item, destination: destination)
                inserted.append(reference)
                guard equal(item, try store.readInserted(reference: reference, original: item)) else { throw AppCredentialTransferError.verification }
            }
        } catch {
            // Only remove the exact new records from this attempt; never delete a group.
            var rollbackFailed = false
            for reference in inserted.reversed() {
                do { try store.removeInserted(reference: reference) } catch { rollbackFailed = true }
            }
            if rollbackFailed { throw AppCredentialTransferError.verification }
            throw error
        }
    }

    static func equal(_ left: AppCredentialItem, _ right: AppCredentialItem) -> Bool {
        left.secret == right.secret && NSDictionary(dictionary: left.attributes).isEqual(to: right.attributes)
    }
}
