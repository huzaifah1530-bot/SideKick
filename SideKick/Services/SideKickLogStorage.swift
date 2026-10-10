import Foundation

enum SideKickLogStorage {
    static let maximumActiveBytes = 5 * 1024 * 1024

    /// Keep recent diagnostic history within 10 MB, excluding the active file.
    static func prune(excluding activeURL: URL) {
        let manager = FileManager.default
        let directory = activeURL.deletingLastPathComponent()
        guard directory.lastPathComponent == "ConsoleLogs",
              let files = try? manager.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]) else { return }
        let archived = files.compactMap { file -> (URL, Int, Date)? in
            guard file != activeURL, file.pathExtension == "log",
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 > $1.2 }
        var retained = 0
        for (file, bytes, _) in archived {
            if retained + bytes <= 10 * 1024 * 1024 { retained += bytes }
            else { try? manager.removeItem(at: file) }
        }
    }
}
