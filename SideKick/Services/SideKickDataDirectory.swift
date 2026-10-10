import Foundation

enum SideKickDataDirectory {
    // Resolve once before Core Data opens. Signing entitlements must never select
    // a different database during the lifetime of the app.
    static let url: URL? = {
        let manager = FileManager.default
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let destination = support.appendingPathComponent("SideKick", isDirectory: true)
        do {
            try manager.createDirectory(at: destination, withIntermediateDirectories: true)
            let database = destination.appendingPathComponent("Database", isDirectory: true)
            let hasPrivateDatabase = ["SideStore.sqlite", "AltStore.sqlite"].contains {
                manager.fileExists(atPath: database.appendingPathComponent($0).path)
            }

            // Older builds preferred an App Group whenever their signer granted
            // one. Copy its data before opening a new private database, keeping
            // the original intact. This migration needs device testing.
            if !hasPrivateDatabase,
               let group = Bundle.main.altstoreAppGroup,
               let legacy = manager.containerURL(forSecurityApplicationGroupIdentifier: group) {
                let legacyDatabase = legacy.appendingPathComponent("Database", isDirectory: true)
                let hasLegacyDatabase = ["SideStore.sqlite", "AltStore.sqlite"].contains {
                    manager.fileExists(atPath: legacyDatabase.appendingPathComponent($0).path)
                }
                if hasLegacyDatabase {
                    // Stage the database including its SQLite WAL before making
                    // it visible at the final path. A failed copy must not cause
                    // Core Data to create an empty replacement database.
                    let stagedDatabase = destination.appendingPathComponent("Database-migration-\(UUID().uuidString)", isDirectory: true)
                    defer { try? manager.removeItem(at: stagedDatabase) }
                    try manager.copyItem(at: legacyDatabase, to: stagedDatabase)
                    let entries = try manager.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)
                    for entry in entries where entry.lastPathComponent != "Database" {
                        let target = destination.appendingPathComponent(entry.lastPathComponent)
                        if !manager.fileExists(atPath: target.path) {
                            try manager.copyItem(at: entry, to: target)
                        }
                    }
                    if manager.fileExists(atPath: database.path) {
                        let preserved = destination.appendingPathComponent("Database-before-migration-\(UUID().uuidString)", isDirectory: true)
                        try manager.moveItem(at: database, to: preserved)
                    }
                    try manager.moveItem(at: stagedDatabase, to: database)
                    debugLog("[SideKick] Migrated legacy App Group data to stable private storage.")
                }
            }
            return destination
        } catch {
            debugLog("[SideKick] Could not prepare private storage: \(error.localizedDescription)")
            return nil
        }
    }()
}
