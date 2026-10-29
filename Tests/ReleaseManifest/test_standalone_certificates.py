from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class StandaloneCertificateTests(unittest.TestCase):
    def test_no_login_or_account_certificate_mutation_in_certificate_scope(self):
        source = (ROOT / 'SideKick/Services/StandaloneCertificateSigning.swift').read_text(encoding='utf-8')
        for forbidden in ['AuthManager', 'setActiveCertificate', 'Account(', 'withAccount(']:
            self.assertNotIn(forbidden, source)
        self.assertIn('SigningAccountOperationCoordinator.acquire()', source)
        self.assertIn('defer { current = nil }', source)
        self.assertIn('profile.certificates.contains', source)

    @unittest.skipUnless(shutil.which('swiftc'), 'Requires Swift compiler')
    def test_actual_certificate_scope_releases_identity_and_gate_on_every_exit(self):
        source = (ROOT / 'SideKick/Services/StandaloneCertificateSigning.swift').read_text(encoding='utf-8')
        source = source.replace('import CoreData', '').replace('import SideSign', '')
        fixture = r"""
import Foundation
enum ImportedCertificateError: Error { case engineBusy, invalidProfile, profileUnavailable, deviceNotInProfile
    case profileRequired(certificateName: String), profileExpired(Date)
}
struct ImportedCertificateRecord { let serialNumber = "CERT"; let name = "Provider"; var profile: Summary? = Summary() }
struct Summary { let uuid = "PROFILE"; let expirationDate = Date.distantFuture; func isExpired() -> Bool { false } }
struct ALTCertificate { let serialNumber = "CERT" }
struct ALTProvisioningProfile { let certificates = [ALTCertificate()]; let deviceIDs: [String] = []
    let teamIdentifier = "CERTTEAM"; let teamName = "Provider team"
}
struct ALTTeam { enum Kind { case individual }; let identifier: String; let name: String; let type: Kind }
struct ImportedCertificateCatalog { static func normalizedSerial(_ serial: String) -> String { serial } }
@MainActor final class ImportedCertificateStore {
    static let shared = ImportedCertificateStore()
    func signingCertificate(serialNumber: String) throws -> (record: ImportedCertificateRecord, certificate: ALTCertificate) {
        (ImportedCertificateRecord(), ALTCertificate())
    }
}
@MainActor enum SigningAccountOperationCoordinator {
    static var occupied = false
    static func acquire() -> Bool { if occupied { return false }; occupied = true; return true }
    static func release() { occupied = false }
}
@MainActor final class AppManager { static let shared = AppManager(); var isActivelyManagingAnyApp = false }
final class ProfileManager { static let shared = ProfileManager(); var missing = false
    func getProfile(uuid: String) -> ALTProvisioningProfile? { missing ? nil : ALTProvisioningProfile() }
}
final class Keychain { static let shared = Keychain(); let deviceUDID: String? = nil }
class Request { var predicate: NSPredicate? }
class Team { init(certificateTeam: ALTTeam, context: Context) { }
    static func fetchRequest() -> Request { Request() }
}
class Context {
    func perform<T>(_ body: () throws -> T) async rethrows -> T { try body() }
    func fetch(_ request: Request) throws -> [Team] { [] }
    func save() throws { }
}
final class DatabaseManager { static let shared = DatabaseManager(); let viewContext = Context() }
enum Probe: Error { case failure }
@main struct Main {
    @MainActor static func main() async throws {
        let record = ImportedCertificateRecord()
        let value = try await StandaloneCertificateSigning.withCertificate(record) {
            precondition(StandaloneCertificateSigning.current?.team.identifier == "CERTTEAM")
            precondition(SigningAccountOperationCoordinator.occupied)
            return 42
        }
        precondition(value == 42 && StandaloneCertificateSigning.current == nil)
        precondition(!SigningAccountOperationCoordinator.occupied)
        do {
            try await StandaloneCertificateSigning.withCertificate(record) { () -> Void in throw Probe.failure }
            fatalError("Operation failure swallowed")
        } catch Probe.failure { }
        precondition(StandaloneCertificateSigning.current == nil && !SigningAccountOperationCoordinator.occupied)
        ProfileManager.shared.missing = true
        do {
            try await StandaloneCertificateSigning.withCertificate(record) { () -> Void in fatalError("Missing profile reached signer") }
            fatalError("Missing profile accepted")
        } catch ImportedCertificateError.profileUnavailable { }
        precondition(StandaloneCertificateSigning.current == nil && !SigningAccountOperationCoordinator.occupied)
        ProfileManager.shared.missing = false
        SigningAccountOperationCoordinator.occupied = true
        do {
            try await StandaloneCertificateSigning.withCertificate(record) { () -> Void in fatalError("Concurrent signer entered") }
            fatalError("Concurrent scope accepted")
        } catch ImportedCertificateError.engineBusy { }
        precondition(SigningAccountOperationCoordinator.occupied)
        SigningAccountOperationCoordinator.occupied = false
        AppManager.shared.isActivelyManagingAnyApp = true
        do {
            try await StandaloneCertificateSigning.withCertificate(record) { () -> Void in fatalError("Busy pipeline entered") }
            fatalError("Busy engine accepted")
        } catch ImportedCertificateError.engineBusy { }
        precondition(StandaloneCertificateSigning.current == nil && !SigningAccountOperationCoordinator.occupied)
    }
}
"""
        with tempfile.TemporaryDirectory(prefix='sidekick-accountless-scope-') as directory:
            path = Path(directory) / 'Scope.swift'
            path.write_text(source + fixture, encoding='utf-8')
            binary = Path(directory) / 'scope'
            subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', str(path), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)
