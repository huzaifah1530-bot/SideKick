"""Apply the shipping patch chain in isolation; never modify the vendor checkout."""
import io
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
VENDOR = ROOT / 'Vendor/SideStore/Dependencies/SideSign'

class AuthCompatibilityPatchTests(unittest.TestCase):
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
            # Exercise the actual response gate, rather than only the later UI dispatch helper.
            gate = auth[auth.index('        let errorCode = status["ec"]'):auth.index('\n        return dictionary', auth.index('        let errorCode = status["ec"]'))]
            self.assertIn('if errorCode != 0 {', gate)
            self.assertNotIn('shouldThrowAuthenticationError', auth)
            constants = (target / 'Sources/Constants.swift').read_text()
            self.assertIn('defaultClientInfo     = AnisetteConstants.defaultClientInfo', constants)
            self.assertIn('defaultUserAgent      = AnisetteConstants.defaultUserAgent', constants)
            manager = (target / 'Sources/Anisette/AnisetteDataManager.swift').read_text()
            self.assertIn('resetProvisioningCache', manager)
            self.assertIn('AuthCompatibility.withProvisioningRecovery', manager)
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
func responsePolicy(status: [String: any Sendable], dictionary: [String: any Sendable], requestParameters: [String: any Sendable], statusCode: Int = 200) throws {
''' + gate + '\n}\n')
                changed_sources = [
                    'Sources/AuthCompatibility.swift', 'Sources/Constants.swift',
                    'Sources/DeveloperPortal/Authentication.swift',
                    'Sources/Anisette/AnisetteDataManager.swift',
                    'Sources/Anisette/RemoteAnisetteDataProvider.swift',
                ]
                subprocess.run(['swiftc', '-frontend', '-parse', *[str(target / name) for name in changed_sources]], check=True)
                binary = target / 'auth-regression'
                subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', str(target / 'Sources/AuthCompatibility.swift'), str(policy), str(ROOT / 'Tests/VendorRegression/AuthCompatibilityRegression.swift'), '-o', str(binary)], check=True)
                subprocess.run([str(binary)], check=True)
            else:
                print('Swift behavioral fixture requires macOS CI (swiftc unavailable locally).')

if __name__ == '__main__':
    unittest.main()
