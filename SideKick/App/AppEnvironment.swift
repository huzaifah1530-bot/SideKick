import Foundation
import Observation
import ZIPFoundation

enum DatabaseStartupState: Equatable {
    case starting
    case ready
    case failed(String)
    case repairing
}

@MainActor
@Observable
final class AppEnvironment {
    let ipaImportStore: IPAImportStore
    private(set) var databaseState: DatabaseStartupState = .starting
    private(set) var databaseBackupURL: URL?

    var canOfferDatabaseReset: Bool {
        !DatabaseManager.shared.isStarted &&
        DatabaseManager.shared.persistentContainer.persistentStoreCoordinator.persistentStores.isEmpty
    }

    init(ipaImportStore: IPAImportStore = IPAImportStore()) {
        self.ipaImportStore = ipaImportStore
    }

    func startDatabase() async {
        if case .ready = databaseState { return }
        databaseState = .starting
        do {
            try await DatabaseManager.shared.start()
            databaseState = .ready
        } catch {
            databaseState = .failed(Self.readableDescription(for: error))
        }
    }

    func backUpAndResetDatabase() async throws {
        guard !DatabaseManager.shared.isStarted,
              DatabaseManager.shared.persistentContainer.persistentStoreCoordinator.persistentStores.isEmpty else {
            throw DatabaseRecoveryError.databaseAlreadyOpen
        }

        databaseState = .repairing
        do {
            let storeURL = DatabaseManager.shared.persistentContainer.persistentStoreDescriptions
                .first?.url
                ?? PersistentContainer.defaultDirectoryURL().appendingPathComponent(AppConstants.Database.fileName)
            let directoryURL = storeURL.deletingLastPathComponent()
            let files = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey]
            )
            guard files.contains(where: { $0.lastPathComponent == storeURL.lastPathComponent }) else {
                throw DatabaseRecoveryError.storeFileMissing
            }

            let backupURL = try Self.createBackup(of: files)
            databaseBackupURL = backupURL

            let fileManager = FileManager.default
            let storeNames = [
                storeURL.lastPathComponent,
                storeURL.lastPathComponent + "-wal",
                storeURL.lastPathComponent + "-shm",
                storeURL.lastPathComponent + "-journal"
            ]
            for name in storeNames {
                let fileURL = directoryURL.appendingPathComponent(name)
                guard fileURL.deletingLastPathComponent().standardizedFileURL == directoryURL.standardizedFileURL else {
                    throw DatabaseRecoveryError.unsafeStorePath
                }
                if fileManager.fileExists(atPath: fileURL.path) {
                    try fileManager.removeItem(at: fileURL)
                }
            }

            DatabaseManager.recreateDatabase()
            try await DatabaseManager.shared.start()
            databaseState = .ready
        } catch {
            databaseState = .failed(Self.readableDescription(for: error))
            throw error
        }
    }

    private static func createBackup(of files: [URL]) throws -> URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backupURL = documentsURL.appendingPathComponent(
            "SideKick-Database-Backup-\(formatter.string(from: .now)).zip"
        )
        let archive = try Archive(url: backupURL, accessMode: .create)
        for fileURL in files {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            try archive.addEntry(
                with: fileURL.lastPathComponent,
                fileURL: fileURL,
                compressionMethod: .deflate
            )
        }
        return backupURL
    }

    private static func readableDescription(for error: Error) -> String {
        let nsError = error as NSError
        var details = [nsError.localizedDescription]
        if let reason = nsError.localizedFailureReason, !reason.isEmpty {
            details.append(reason)
        }
        if let debug = nsError.userInfo[NSDebugDescriptionErrorKey] as? String, !debug.isEmpty {
            details.append(debug)
        }
        return Array(NSOrderedSet(array: details)).compactMap { $0 as? String }.joined(separator: "\n\n")
    }
}

private enum DatabaseRecoveryError: LocalizedError {
    case databaseAlreadyOpen
    case storeFileMissing
    case unsafeStorePath

    var errorDescription: String? {
        switch self {
        case .databaseAlreadyOpen:
            "SideStore’s database is already open. Close and reopen SideKick before trying recovery."
        case .storeFileMissing:
            "The SideStore database file could not be found, so SideKick could not create a backup."
        case .unsafeStorePath:
            "SideKick stopped because the database recovery path was not safe."
        }
    }
}
