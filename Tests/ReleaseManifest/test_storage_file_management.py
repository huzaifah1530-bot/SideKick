from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class StorageFileManagementTests(unittest.TestCase):
    def test_only_important_files_prompt_and_library_deletion_updates_records(self):
        view = (ROOT / 'SideKick/Views/Settings/StorageFilesView.swift').read_text(encoding='utf-8')
        self.assertIn('if review.warning != nil { confirming = true }', view)
        self.assertIn('else { Task { await remove(confirmed: false) } }', view)
        runtime = (ROOT / 'SideKick/Services/ManagedStorageFiles.swift').read_text(encoding='utf-8')
        self.assertIn('latest.warning == review.warning', runtime)
        self.assertIn('try await IPAImportStore.shared.delete(app)', runtime)
        self.assertIn('beginStorageRemoval()', runtime)
        directory = (ROOT / 'SideKick/Services/SideKickDataDirectory.swift').read_text(encoding='utf-8')
        self.assertLess(directory.index('if let cachedURL'), directory.index('DeferredStorageRemoval.applyBeforeDatabaseStart()'))

    @unittest.skipUnless(shutil.which('swiftc'), 'Deferred deletion filesystem behavior requires Swift')
    def test_queued_deletion_stays_in_owned_roots_and_does_not_follow_links(self):
        runtime = (ROOT / 'SideKick/Services/ManagedStorageFiles.swift').read_text(encoding='utf-8')
        deferred = runtime[runtime.index('enum DeferredStorageRemoval {'):runtime.index('@MainActor\nenum ManagedStorageFiles')]
        cleanup = (ROOT / 'SideKick/Services/SideKickStorageCleanup.swift').read_text(encoding='utf-8')
        owned = cleanup[cleanup.index('enum OwnedStoragePath {'):cleanup.index('struct StorageRemovalPolicy')]
        fixture = '''import Foundation
enum StorageCleanupError: Error { case unsafePath }
extension Bundle { var altstoreAppGroup: String? { nil } }
func debugLog(_ value: String) {}
OWNED
DEFERRED
@main struct Main {
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("storage-test-" + UUID().uuidString)
        let outside = manager.temporaryDirectory.appendingPathComponent("storage-keep-" + UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outside)
        defer { try? manager.removeItem(at: root); try? manager.removeItem(at: outside) }
        try Data("remove".utf8).write(to: root.appendingPathComponent("old.ipa"))
        try manager.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        do { _ = try DeferredStorageRemoval.validate(URL(fileURLWithPath: "/etc/hosts")); fatalError("Escaped owned storage") } catch {}
        DeferredStorageRemoval.queue(root)
        precondition(manager.fileExists(atPath: root.path))
        DeferredStorageRemoval.applyBeforeDatabaseStart()
        precondition(!manager.fileExists(atPath: root.path))
        let kept = try Data(contentsOf: outside)
        precondition(kept == Data("keep".utf8))
        print("Deferred file deletion and symlink confinement passed")
    }
}
'''.replace('OWNED', owned).replace('DEFERRED', deferred)
        with tempfile.TemporaryDirectory(prefix='sidekick-storage-test-') as directory:
            path = Path(directory)
            source = path / 'Deferred.swift'
            source.write_text(fixture, encoding='utf-8')
            binary = path / 'deferred'
            subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', str(source), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)
