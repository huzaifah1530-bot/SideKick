"""Apply the shipping patch chain in isolation; never modify the vendor checkout."""
import io
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
VENDOR = ROOT / 'Vendor/SideStore/Dependencies/SideSign'

class AuthCompatibilityPatchTests(unittest.TestCase):
    def test_sidestore_passes_frozen_remote_identity_to_resync(self):
        vendor = ROOT / 'Vendor/SideStore'
        with tempfile.TemporaryDirectory(prefix='sidekick-resync-wiring-') as tmp:
            target = Path(tmp)
            archive = subprocess.check_output(['git', '-C', str(vendor), 'archive', 'HEAD'])
            with tarfile.open(fileobj=io.BytesIO(archive)) as files:
                files.extractall(target, filter='data')
            for name in ('sidestore-sidekick.patch', 'sidestore-certificate-error-classification.patch',
                         'sidestore-use-account-certificate-for-refresh.patch', 'sidestore-compiler-workarounds.patch',
                         'sidestore-view-body-compile.patch', 'sidestore-audit-fixes.patch',
                         'sidestore-anisette-recovery.patch', 'sidestore-diagnostics.patch'):
                if name == 'sidestore-audit-fixes.patch':
                    subprocess.run([sys.executable, str(ROOT / 'scripts/embed-local-vpn.py'), str(target)], check=True, capture_output=True)
                args = ['git', '-C', str(target), 'apply']
                if name in ('sidestore-certificate-error-classification.patch', 'sidestore-use-account-certificate-for-refresh.patch'):
                    args.append('--unidiff-zero')
                applied = subprocess.run([*args, str(ROOT / 'patches' / name)], capture_output=True, text=True)
                self.assertEqual(applied.returncode, 0, f'{name}: {applied.stderr}')
            provider = (target / 'SideStore/Core/Anisette/AnisetteProvider.swift').read_text()
            proxy = (target / 'SideStore/Core/Auth/DeveloperPortalProxy.swift').read_text()
            self.assertIn('UUID(uuidString: data.deviceID) == identifier', provider)
            self.assertIn('resynchronize(identifier: identifier, adiBlob: blob', provider)
            self.assertIn('anisetteResyncHandler: resyncHandler', proxy)

    def test_patch_applies_after_audit_and_preserves_redaction(self):
        with tempfile.TemporaryDirectory(prefix='sidekick-auth-test-') as tmp:
            target = Path(tmp)
            archive = subprocess.check_output(['git', '-C', str(VENDOR), 'archive', 'HEAD'])
            with tarfile.open(fileobj=io.BytesIO(archive)) as files:
                files.extractall(target, filter='data')
            for name in ('sidesign-audit-fixes.patch', 'sidesign-auth-compatibility.patch'):
                patch = ROOT / 'patches' / name
                self.assertTrue(patch.exists(), f'Missing shipping patch: {name}')
                subprocess.run(['git', '-C', str(target), 'apply', str(patch)], check=True, capture_output=True)
            auth = (target / 'Sources/DeveloperPortal/Authentication.swift').read_text()
            self.assertIn('redactedAuthenticationPayload', auth)
            self.assertNotIn('token: \\(idmsToken)', auth)
            self.assertIn('codeAlreadySent: pushedCode', auth)
            self.assertIn('PushedCodeState.handled', auth)
            two_factor = auth[auth.index('    private func makeTwoFactorAuthRequest'):]
            self.assertIn('a.userAgent.isEmpty ? h.developerServices.userAgent : a.userAgent', two_factor)
            self.assertIn('AuthenticationDiagnostics.record', auth)
            # Exercise the actual response gate, rather than only the later UI dispatch helper.
            gate = auth[auth.index('        let errorCode = status["ec"]'):auth.index('\n        return dictionary', auth.index('        let errorCode = status["ec"]'))]
            self.assertIn('if errorCode != 0 {', gate)
            self.assertNotIn('shouldThrowAuthenticationError', auth)
            constants = (target / 'Sources/Constants.swift').read_text()
            self.assertIn('defaultClientInfo     = AnisetteConstants.defaultClientInfo', constants)
            self.assertIn('defaultUserAgent      = AnisetteConstants.defaultUserAgent', constants)
            manager = (target / 'Sources/Anisette/AnisetteDataManager.swift').read_text()
            remote = (target / 'Sources/Anisette/RemoteAnisetteDataProvider.swift').read_text()
            self.assertEqual(remote.count('let cleanIdentifier = AuthCompatibility.remoteIdentifier(identifier)'), 2,
                             'Provisioning and get_headers must send the same Base64 UUID bytes')
            self.assertIn('resetProvisioningCache', manager)
            self.assertIn('AuthCompatibility.withProvisioningRecovery', manager)
            self.assertIn('AuthCompatibility.withResynchronization', auth)
            self.assertIn('allowAnisetteResync: allowResync', auth)
            self.assertIn('AuthCompatibility.resyncPayload(status: status)', gate)
            self.assertIn('AuthCompatibility.resyncRequest', remote)
            self.assertIn('AuthenticationDiagnostics.record(.anisetteResync', remote)
            self.assertIn('completionHandler(nil)', remote)
            self.assertNotIn('jsonPayload: String(data:', remote)
            self.assertIn('cpd["X-Apple-I-MD"] = data.oneTimePassword', auth)
            self.assertIn('clientDictionary["X-Apple-I-MD"] = anisetteData.oneTimePassword', auth)
            if shutil.which('swiftc'):
                # Compile the response gate extracted from the patched production method.
                # Stub only its error types and logging; the branch and error dispatch are real.
                policy = target / 'ResponsePolicy.swift'
                policy.write_text('''import Foundation
enum GrandSlamAuthErrorCodes {
    static let incorrectCredentials = -22406
    static let appSpecificPasswordRequired = -20101
    static let appSpecificPasswordRequiredFallback = -20209
    static let incorrectVerificationCode = -21669
}
struct DeveloperPortalError: Error {
    static func incorrectCredentials() -> Self { Self() }
    static func appSpecificPasswordRequired() -> Self { Self() }
    static func incorrectVerificationCode() -> Self { Self() }
}
enum ServerError: Error { case underlyingError(code: Int, message: String) }
func debugLog(_ value: String) { }
@discardableResult func responsePolicy(status: [String: any Sendable], dictionary: [String: any Sendable], requestParameters: [String: any Sendable], statusCode: Int = 200, allowAnisetteResync: Bool = false) throws -> [String: any Sendable] {
let diagnosticStage = AuthenticationDiagnostics.Stage.authComplete
''' + gate + '\nreturn dictionary\n}\n')
                changed_sources = [
                    'Sources/AuthCompatibility.swift', 'Sources/Constants.swift',
                    'Sources/DeveloperPortal/Authentication.swift',
                    'Sources/Anisette/AnisetteDataManager.swift',
                    'Sources/Anisette/RemoteAnisetteDataProvider.swift',
                ]
                subprocess.run(['swiftc', '-frontend', '-parse', *[str(target / name) for name in changed_sources]], check=True)
                binary = target / 'auth-regression'
                subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', str(target / 'Sources/AuthCompatibility.swift'), str(target / 'Sources/AuthenticationDiagnostics.swift'), str(policy), str(ROOT / 'Tests/VendorRegression/AuthCompatibilityRegression.swift'), '-o', str(binary)], check=True)
                subprocess.run([str(binary)], check=True)
            else:
                print('Swift behavioral fixture requires macOS CI (swiftc unavailable locally).')

if __name__ == '__main__':
    unittest.main()
