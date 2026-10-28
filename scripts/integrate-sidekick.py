"""Run after SideKick patches; applies SideKick integration edits to the vendored SideStore tree."""
from pathlib import Path
import re
import sys

root = Path(sys.argv[1] if len(sys.argv) > 1 else "Vendor/SideStore")
app_delegate = root / "AltStore/AppDelegate.swift"
source = app_delegate.read_text(encoding="utf-8")
original = "        _ = try? AppManager.shared.backgroundRefresh(installedApps, completionHandler: refreshAppsCompletionHandler)"
replacement = """        Task { @MainActor in
            await DailyRefreshReminderScheduler.update()
            await GitHubUpdateScanner.scanAndNotify()
            do {
                let lease = try await LocalVPNService.shared.acquire()
                do {
                    _ = try AppManager.shared.backgroundRefresh(installedApps) { result in
                        Task { @MainActor in
                            LocalVPNService.shared.release(lease)
                            if case .success(let apps) = result, !apps.isEmpty,
                               apps.values.allSatisfy({ if case .success = $0 { return true }; return false }) {
                                await DailyRefreshReminderScheduler.recordSuccess()
                            }
                            refreshAppsCompletionHandler(result)
                        }
                    }
                } catch {
                    LocalVPNService.shared.release(lease)
                    refreshAppsCompletionHandler(.failure(error))
                }
            } catch {
                refreshAppsCompletionHandler(.failure(error))
            }
        }"""
if source.count(original) != 1:
    raise RuntimeError("Upstream background refresh integration point changed")
app_delegate.write_text(source.replace(original, replacement, 1), encoding="utf-8")

build_config = root / "Build.xcconfig"
source = build_config.read_text(encoding="utf-8")
source, count = re.subn(r"^MARKETING_VERSION = .*$", "MARKETING_VERSION = 0.10.0", source, count=1, flags=re.M)
if count != 1:
    raise RuntimeError("Missing app marketing version")
build_config.write_text(source, encoding="utf-8")

# SideKick uses its own multi-account Keychain vault. Legacy SideStore
# maintenance must not force users out of accounts on an update/migration.
maintenance = root / "SideStore/MaintenanceManager.swift"
source = maintenance.read_text(encoding="utf-8")
for original in [
    "                Keychain.shared.clearAll()\n                await AuthManager.shared.signOut(keepCertificate: false, keepAnisetteData: false)",
    "                AnisetteDataManager.shared.clearCache()\n                await AuthManager.shared.signOut(keepCertificate: true, keepAnisetteData: false)",
]:
    if source.count(original) != 1:
        raise RuntimeError("Upstream account maintenance integration point changed")
    source = source.replace(original, "                AnisetteDataManager.shared.clearCache()", 1)
maintenance.write_text(source, encoding="utf-8")
source = app_delegate.read_text(encoding="utf-8")
original = "                if isFirstLaunch\n                {\n                    await AuthManager.shared.signOut()\n                }"
if source.count(original) != 1:
    raise RuntimeError("Upstream first-launch account integration point changed")
source = source.replace(original, "                // Keep saved Apple Accounts across SideKick updates.", 1)
app_delegate.write_text(source, encoding="utf-8")

# Bound verbose diagnostics instead of accumulating unlimited session logs.
console = root / "SideStore/Utils/iostreams/ConsoleLog.swift"
source = console.read_text(encoding="utf-8")
original = "            fileHandle: logFileHandle,"
if source.count(original) != 1:
    raise RuntimeError("Upstream console stream integration changed")
source = source.replace(original, original + "\n            maximumBytes: SideKickLogStorage.maximumActiveBytes,", 1)
original = "        let parentDir = url.deletingLastPathComponent()"
if source.count(original) != 1:
    raise RuntimeError("Upstream console file integration changed")
source = source.replace(original, original + "\n        SideKickLogStorage.prune(excluding: url)", 1)
console.write_text(source, encoding="utf-8")
stream = root / "SideStore/Utils/common/FileOutputStream.swift"
source = stream.read_text(encoding="utf-8")
source = source.replace("    private var fileHandle: FileHandle?", "    private var maximumBytes: Int?\n    private var fileHandle: FileHandle?", 1)
source = source.replace("public init(fileHandle: FileHandle, fileHandleProvider:", "public init(fileHandle: FileHandle, maximumBytes: Int? = nil, fileHandleProvider:", 1)
source = source.replace("        self.fileHandle = fileHandle", "        self.maximumBytes = maximumBytes\n        self.fileHandle = fileHandle", 1)
source = source.replace("try fileHandle.write(contentsOf: data)", "try writeBounded(data, to: fileHandle)", 1)
source = source.replace("try newHandle.write(contentsOf: data)", "try writeBounded(data, to: newHandle)", 1)
original = "    private func ensureFileHandle() throws {"
replacement = """    private func writeBounded(_ data: Data, to handle: FileHandle) throws {
        guard let maximumBytes, maximumBytes > 0 else {
            try handle.write(contentsOf: data)
            return
        }
        let chunk = data.suffix(maximumBytes)
        if try handle.offset() + UInt64(chunk.count) > UInt64(maximumBytes) {
            try handle.truncate(atOffset: 0)
            try handle.seek(toOffset: 0)
        }
        try handle.write(contentsOf: chunk)
    }

    private func ensureFileHandle() throws {"""
if source.count(original) != 1:
    raise RuntimeError("Upstream file stream integration changed")
stream.write_text(source.replace(original, replacement, 1), encoding="utf-8")
