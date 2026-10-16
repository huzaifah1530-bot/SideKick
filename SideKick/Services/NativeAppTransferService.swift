import CoreData
import Foundation
import SideSign
import UIKit

enum NativeTransferAction: Equatable { case export, offload, restore, recover }

struct NativeTransferRecord: Codable {
    var state: String = "notStarted"
    var dataBookmark: Data?
    var guestVerified = false
}

@MainActor
final class NativeAppTransferService {
    private static var running = false
    static var isRunning: Bool { running }
    static func hasUnfinishedTransfer(_ appID: String) -> Bool {
        guard let data = UserDefaults.standard.data(forKey: "SideKick.transfer." + appID),
              let record = try? JSONDecoder().decode(NativeTransferRecord.self, from: data) else { return false }
        return ["offloaded", "exporting", "offloading", "restoring", "recoveryNeeded"].contains(record.state)
    }
    private let app: InstalledAppSummary
    private let accounts: SigningAccountStore

    init(app: InstalledAppSummary, accounts: SigningAccountStore) {
        self.app = app
        self.accounts = accounts
    }

    var record: NativeTransferRecord {
        get {
            guard let data = UserDefaults.standard.data(forKey: "SideKick.transfer." + app.id) else { return NativeTransferRecord() }
            return (try? JSONDecoder().decode(NativeTransferRecord.self, from: data)) ?? NativeTransferRecord()
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "SideKick.transfer." + app.id)
            }
        }
    }

    func retainDataFolder(_ url: URL) throws {
        guard url.startAccessingSecurityScopedResource() else { throw AppDataTransferError.invalidFolder }
        defer { url.stopAccessingSecurityScopedResource() }
        let identity = try AppDataTransfer.readIdentity(at: url)
        guard identity.bundleIdentifier == app.id, identity.version == app.version, identity.build == app.buildVersion else {
            throw AppDataTransferError.identityMismatch
        }
        var updated = record
        updated.dataBookmark = try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
        updated.guestVerified = false
        record = updated
    }

    private func installedRecord() async throws -> InstalledApp {
        guard app.id != Bundle.Info.activeBundleIdentifier,
              !app.bundleIdentifier.lowercased().contains("livecontainer") else {
            throw NativeTransferError.unsupported
        }
        let context = DatabaseManager.shared.viewContext
        guard let installed = try await context.perform({
            try context.fetch(InstalledApp.fetchRequest()).first { $0.resignedBundleIdentifier == self.app.id }
        }), let bundle = ALTApplication(fileURL: installed.fileURL) else { throw NativeTransferError.sourceMissing }
        // The first version transfers the main app home only.
        let groups = bundle.entitlements[.appGroups] as? [String] ?? []
        guard groups.isEmpty else { throw NativeTransferError.appGroups }
        guard bundle.version == app.version, bundle.buildVersion == app.buildVersion else {
            throw AppDataTransferError.identityMismatch
        }
        return installed
    }

    func prepareGuestIPA() async throws -> URL {
        guard !Self.running else { throw NativeTransferError.inUse }
        Self.running = true
        defer { Self.running = false }
        try SideKickStorageCleanup.beginOperation()
        defer { SideKickStorageCleanup.endOperation() }
        let installed = try await installedRecord()
        let sourceURL = installed.fileURL
        let identity = app.id
        let packaging = Task.detached(priority: .userInitiated) {
            try Self.packageGuestIPA(sourceURL: sourceURL, identity: identity)
        }
        return try await withTaskCancellationHandler {
            try await packaging.value
        } onCancel: {
            packaging.cancel()
        }
    }

    private nonisolated static func packageGuestIPA(sourceURL: URL, identity: String) throws -> URL {
        try Task.checkCancellation()
        let fm = FileManager.default
        let root = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("LiveContainerTransfers")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let temporary = fm.temporaryDirectory.appendingPathComponent("SideKickGuest-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let copy = temporary.appendingPathComponent("Guest.app")
        try fm.copyItem(at: sourceURL, to: copy)
        guard let bundle = ALTApplication(fileURL: copy) else { throw NativeTransferError.sourceMissing }
        // Keep the native preference-domain identity when LiveContainer launches.
        try bundle.updateInfoPlist(with: ["CFBundleIdentifier": identity])
        try Task.checkCancellation()
        let zipped = try fm.zipAppBundle(at: copy, compressionLevel: .none)
        try Task.checkCancellation()
        let output = root.appendingPathComponent(UUID().uuidString + ".ipa")
        do { try fm.copyItem(at: zipped, to: output) }
        catch { try? fm.removeItem(at: output); throw error }
        try? fm.removeItem(at: zipped)
        return output
    }

    func perform(_ action: NativeTransferAction) async throws {
        guard !Self.running else { throw NativeTransferError.inUse }
        Self.running = true
        defer { Self.running = false }
        let installed = try await installedRecord()
        if action == .export || action == .offload {
            guard installed.isActive else { throw NativeTransferError.transferPending }
        }
        guard let presenter = UIApplication.shared.topViewController() else { throw NativeTransferError.inUse }
        if action == .offload {
            guard record.guestVerified, let bookmark = record.dataBookmark else { throw NativeTransferError.unverified }
            var stale = false
            let folder = try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
            guard !stale else { throw AppDataTransferError.invalidFolder }
            try retainDataFolder(folder)
            var updated = record; updated.guestVerified = true; record = updated
        }
        try SideKickStorageCleanup.beginOperation()
        defer { SideKickStorageCleanup.endOperation() }
        let lease = try await LocalVPNService.shared.acquire()
        defer { LocalVPNService.shared.release(lease) }
        let previous = UserDefaults.standard.object(forKey: "SideKickFileTransferRequest")
        let legacy = UserDefaults.standard.isLegacyDeactivationSupported
        UserDefaults.standard.set(action != .recover, forKey: "SideKickFileTransferRequest")
        UserDefaults.standard.isLegacyDeactivationSupported = false
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: "SideKickFileTransferRequest") }
            else { UserDefaults.standard.removeObject(forKey: "SideKickFileTransferRequest") }
            UserDefaults.standard.isLegacyDeactivationSupported = legacy
        }
        var updated = record
        updated.state = action == .restore ? "restoring" : action == .offload ? "offloading" : "exporting"
        record = updated
        do {
            try await accounts.withAccount(accountIdentifier: app.accountIdentifier, teamIdentifier: app.teamIdentifier) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let finished: (Result<InstalledApp, Error>) -> Void = { continuation.resume(with: $0.map { _ in () }) }
                    switch action {
                    case .export: AppManager.shared.backup(installed, presentingViewController: presenter, completionHandler: finished)
                    case .offload: AppManager.shared.deactivate(installed, presentingViewController: presenter, completionHandler: finished)
                    case .restore:
                        if installed.isActive { AppManager.shared.restore(installed, presentingViewController: presenter, completionHandler: finished) }
                        else { AppManager.shared.activate(installed, presentingViewController: presenter, completionHandler: finished) }
                    case .recover: AppManager.shared.reinstall(installed, presentingViewController: presenter, completionHandler: finished)
                    }
                }
            }
            updated = record
            updated.state = action == .offload ? "offloaded" : action == .restore ? "restored" : action == .recover ? "binaryRecovered" : "exported"
            if action != .offload { updated.guestVerified = false }
            record = updated
            await ExpirationNotificationScheduler.update()
        } catch {
            updated = record
            updated.state = "recoveryNeeded"
            updated.guestVerified = false
            record = updated
            throw error
        }
    }
}

enum NativeTransferError: LocalizedError {
    case unsupported, appGroups, sourceMissing, inUse, unverified, transferPending
    var errorDescription: String? {
        switch self {
        case .unsupported: "SideKick and LiveContainer cannot be moved using this transfer."
        case .appGroups: "This app uses App Groups. The first transfer version supports Documents and Library only; keep this app installed."
        case .sourceMissing: "The retained app source is unavailable. Import the original IPA before continuing."
        case .inUse: "Another transfer is running or the app cannot present the transfer screen."
        case .unverified: "Select the exported data folder and verify the guest in LiveContainer before freeing the native slot."
        case .transferPending: "This app is offloaded or has an unfinished transfer. Open Move to LiveContainer to restore or recover it first."
        }
    }
}
