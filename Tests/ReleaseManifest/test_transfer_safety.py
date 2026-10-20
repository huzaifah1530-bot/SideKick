"""A transfer manifest must never become authority to uninstall an app."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class TransferSafetyTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required for certificate cleanup behavior')
    def test_certificate_cleanup_success_busy_and_keychain_failure(self):
        source = (ROOT / 'SideKick/Services/ImportedCertificateStore.swift').read_text(encoding='utf-8')
        method = source[source.index('    func delete('):source.index('    /// Points SideStore')]
        fixture = r'''
import Foundation
struct Profile { let uuid: String }
struct ImportedCertificateRecord { let serialNumber: String; var profile: Profile? = nil }
struct Catalog {
    var records = [ImportedCertificateRecord(serialNumber: "ABCD")]
    func record(serialNumber: String) -> ImportedCertificateRecord? { records.first { $0.serialNumber == serialNumber } }
    mutating func remove(serialNumber: String) { records.removeAll { $0.serialNumber == serialNumber } }
}
enum ImportedCertificateError: Error { case engineBusy, keychain }
enum SigningAccountOperationCoordinator {
    static var busy = false
    static func acquire() -> Bool { if busy { return false }; busy = true; return true }
    static func release() { busy = false }
}
class AppManager { static let shared = AppManager(); let isActivelyManagingAnyApp = false }
enum AppOffloadService { static let isRunning = false }
enum SideKickStorageCleanup { static let hasActiveOperations = false }
class CertificateManager {
    static let shared = CertificateManager()
    var activeCertificate: ImportedCertificateRecord?
    var fail = false
    func clearActiveCertificateThrowing() throws {
        if fail { throw ImportedCertificateError.keychain }
        activeCertificate = nil
    }
}
enum ImportedCertificateCatalogFile { static var saved = 0; static func save(_ value: Catalog) throws { saved += 1 } }
class ProfileManager { static let shared = ProfileManager(); func deleteProfile(uuid: String) {} }
struct Vault { func delete(serialNumber: String) throws {} }
class Store {
    var catalog = Catalog()
    let vault = Vault()
METHOD
}
@main struct Main {
    static func main() throws {
        let record = ImportedCertificateRecord(serialNumber: "ABCD")
        let manager = CertificateManager.shared
        let store = Store()
        manager.activeCertificate = ImportedCertificateRecord(serialNumber: "abcd")
        try store.delete(record)
        precondition(manager.activeCertificate == nil && store.catalog.records.isEmpty)
        store.catalog = Catalog()
        manager.activeCertificate = ImportedCertificateRecord(serialNumber: "OTHER")
        try store.delete(record)
        precondition(manager.activeCertificate?.serialNumber == "OTHER")
        store.catalog = Catalog()
        manager.activeCertificate = record
        SigningAccountOperationCoordinator.busy = true
        do { try store.delete(record); fatalError("Busy signing must block deletion") } catch ImportedCertificateError.engineBusy {}
        precondition(!store.catalog.records.isEmpty && manager.activeCertificate != nil)
        SigningAccountOperationCoordinator.busy = false
        manager.fail = true
        let before = ImportedCertificateCatalogFile.saved
        do { try store.delete(record); fatalError("Keychain failure must abort deletion") } catch ImportedCertificateError.keychain {}
        precondition(!store.catalog.records.isEmpty && ImportedCertificateCatalogFile.saved == before)
        precondition(!SigningAccountOperationCoordinator.busy)
        print("Imported certificate deletion safety passed")
    }
}
'''.replace('METHOD', method)
        with tempfile.TemporaryDirectory(prefix='sidekick-certificate-cleanup-') as directory:
            root = Path(directory)
            path = root / 'Cleanup.swift'
            path.write_text(fixture, encoding='utf-8')
            binary = root / 'cleanup'
            subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', str(path), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)

    def test_certificate_deletion_clears_identity_before_forgetting_ownership(self):
        source = (ROOT / 'SideKick/Services/ImportedCertificateStore.swift').read_text(encoding='utf-8')
        deletion = source[source.index('    func delete('):source.index('    func prepareProfileAssignment(')]
        self.assertIn('SigningAccountOperationCoordinator.acquire()', deletion)
        self.assertIn('caseInsensitiveCompare(record.serialNumber)', deletion)
        self.assertIn('clearActiveCertificateThrowing()', deletion)
        self.assertLess(deletion.index('clearActiveCertificateThrowing()'),
                        deletion.index('ImportedCertificateCatalogFile.save(updated)'))

    def test_untrusted_transfer_cannot_uninstall_an_app(self):
        service = (ROOT / 'SideKick/Services/SideKickTransferService.swift').read_text(encoding='utf-8')
        view = (ROOT / 'SideKick/Views/Settings/SideKickTransferViews.swift').read_text(encoding='utf-8')
        self.assertNotIn('removeApp(', service)
        self.assertNotIn('deleteOldCopy(', service + view)
        self.assertIn('delete the old copy through iOS', view)


if __name__ == '__main__':
    unittest.main()
