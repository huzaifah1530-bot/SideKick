from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class CertificateRecoveryTests(unittest.TestCase):
    def test_shipping_signer_keeps_explicit_profiles_compatible(self):
        relative = 'Sources/CodeSigning/CodeSignerAPI.swift'
        with tempfile.TemporaryDirectory(prefix='sidekick-profile-identity-') as directory:
            root = Path(directory)
            source = root / relative
            source.parent.mkdir(parents=True)
            source.write_bytes(subprocess.check_output(['git', '-C', str(ROOT / 'Vendor/SideStore/Dependencies/SideSign'), 'show', 'HEAD:' + relative]))
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            for name in ['sidesign-audit-fixes.patch', 'sidesign-required-app-groups.patch', 'sidesign-wildcard-application-identifier.patch']:
                patch = root / 'change.patch'
                patch.write_bytes((ROOT / 'patches' / name).read_text(encoding='utf-8').encode())
                subprocess.run(['git', '-C', str(root), 'apply', '--include=' + relative, str(patch)], check=True)
            text = source.read_text(encoding='utf-8')
            block = text[text.index('            // Expand wildcard profiles'):text.index('            verboseLog("[SideSign] Filtered entitlements')]
            self.assertNotIn('guard matches', block)
            self.assertIn('prefix + "." + app.bundleIdentifier', block)
            if not shutil.which('swiftc'):
                return
            fixture = '''import Foundation
enum SignerError: Error { case invalidApp(cause: String) }
struct App { let bundleIdentifier: String }
func identity(_ allowed: String, _ bundle: String) throws -> String {
    let app = App(bundleIdentifier: bundle)
    var filteredEntitlements: [String: Any] = ["application-identifier": allowed]
BLOCK
    return filteredEntitlements["application-identifier"] as! String
}
@main struct Main {
    static func main() throws {
        let first = try identity("OLDPREFIX.*", "com.spotify.client")
        precondition(first == "OLDPREFIX.com.spotify.client")
        let second = try identity("OLDPREFIX.com.spotify.*", "com.spotify.client")
        precondition(second == "OLDPREFIX.com.spotify.client")
        let third = try identity("OLDPREFIX.com.spotify.client", "com.spotify.client")
        precondition(third == "OLDPREFIX.com.spotify.client")
        let fixed = try identity("TEAM.com.sidekick.app", "com.spotify.client")
        precondition(fixed == "TEAM.com.sidekick.app")

        print("Per-app signing identity regression passed")
    }
}
'''.replace('BLOCK', block)
            harness = root / 'Identity.swift'
            harness.write_text(fixture, encoding='utf-8')
            binary = root / 'identity'
            subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', str(harness), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)

    def test_false_offload_restore_does_not_require_shared_backup_helper(self):
        source = (ROOT / 'SideKick/Services/AppOffloadService.swift').read_text(encoding='utf-8')
        self.assertIn('let recoverBinary = restoring && !hasBackup', source)
        self.assertIn('func forgetSavedApp()', source)

    def test_cross_team_resign_is_rejected_before_installation(self):
        source = (ROOT / 'SideKick/Services/SideStoreOperationService.swift').read_text(encoding='utf-8')
        resign = source[source.index('    private func performResign('):source.index('    /// Whether the certificate')]
        self.assertIn('SigningIdentityPolicy.validateResign', resign)
        self.assertLess(resign.index('SigningIdentityPolicy.validateResign'), resign.index('LocalVPNService.shared.acquire'))

    def test_reminders_are_armed_without_shortcut_and_success_reschedules(self):
        source = (ROOT / 'SideKick/Services/ExpirationNotificationScheduler.swift').read_text(encoding='utf-8')
        self.assertIn('await DailyRefreshReminderScheduler.update()', source)
        shortcut = (ROOT / 'SideKick/Services/DailyRefreshShortcut.swift').read_text(encoding='utf-8')
        self.assertIn('await DailyRefreshReminderScheduler.recordSuccess()', shortcut)
        self.assertNotIn('await report.notifyIfNeeded()', shortcut)
