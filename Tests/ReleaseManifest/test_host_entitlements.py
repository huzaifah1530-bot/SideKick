"""Shipping host permissions survive packaging and on-device signing."""
import importlib.util
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[2]
GROUP = 'com.apple.security.application-groups'
VPN_KEYS = ('com.apple.developer.networking.networkextension', 'com.apple.developer.networking.vpn.api')


class HostEntitlementTests(unittest.TestCase):
    def signer_source(self):
        relative = 'Sources/CodeSigning/CodeSignerAPI.swift'
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / relative
            path.parent.mkdir(parents=True)
            path.write_bytes(subprocess.check_output(['git', '-C', str(ROOT / 'Vendor/SideStore/Dependencies/SideSign'), 'show', 'HEAD:' + relative]))
            subprocess.run(['git', 'init', '--quiet', str(root)], check=True)
            patch_path = root / 'required-groups.patch'
            patch_path.write_bytes((ROOT / 'patches/sidesign-required-app-groups.patch').read_text(encoding='utf-8').encode('utf-8'))
            subprocess.run(['git', '-C', str(root), 'apply', str(patch_path)], check=True)
            return path.read_text()

    def test_required_groups_are_scoped_to_a_bundle_and_checked_against_its_profile(self):
        signer = self.signer_source()
        self.assertIn('requiredAppGroups[app.bundleIdentifier]', signer)
        self.assertIn('requestedGroups.allSatisfy({ grantedGroups.contains($0) })', signer)
        self.assertIn('applicationEntitlements[groupKey] = requestedGroups', signer)
        original_api = 'public func signApp(at appURL: URL, provisioningProfiles profiles: [ProvisioningProfile], progress: Progress? = nil) async throws'
        self.assertIn(original_api, signer, 'Keep the original CodeSignerAPI protocol entry point')
        workflow = (ROOT / '.github/workflows/ios-build.yml').read_text()
        self.assertIn('patches/sidesign-required-app-groups.patch', workflow)

    def module(self):
        spec = importlib.util.spec_from_file_location('host_entitlements', ROOT / 'scripts/host-entitlements.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_both_variants_keep_groups_and_only_external_vpn_permissions_are_removed(self):
        module = self.module()
        configured = plistlib.loads((ROOT / 'SideKickVPN/Host.entitlements').read_bytes())
        self.assertEqual(configured[GROUP], ['group.com.sidekick.app', 'group.com.SideStore.SideStore'])
        # Additional permission requests must survive without another allowlist.
        configured['keychain-access-groups'] = ['TEAM.com.sidekick.app']
        configured['com.apple.developer.siri'] = True
        self.assertEqual(module.requests(configured, external_vpn=False), configured)
        self.assertEqual(module.requests(configured, external_vpn=True),
                         {key: value for key, value in configured.items() if key not in VPN_KEYS})
        self.assertIn(VPN_KEYS[0], configured, 'Filtering must not mutate the input')
        with self.assertRaisesRegex(ValueError, 'App Group'):
            module.requests({})

    def test_workflow_verifies_both_final_archives_before_upload(self):
        workflow = (ROOT / '.github/workflows/ios-build.yml').read_text()
        self.assertNotIn('plistlib.dumps({})', workflow)
        self.assertIn('host-entitlements.py prepare SideKickVPN/Host.entitlements', workflow)
        for name in ('SideKick-unsigned.ipa', 'SideKick-vpn-unsigned.ipa'):
            call = f'host-entitlements.py verify artifacts/{name}'
            self.assertIn(call, workflow)
            self.assertLess(workflow.index(call), workflow.index('- name: Upload IPA artifact'))

    def test_packaged_ipa_inspection_rejects_missing_or_changed_permissions(self):
        module = self.module()
        expected = {GROUP: ['group.com.sidekick.app', 'group.com.SideStore.SideStore'], 'com.apple.developer.siri': True}
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / 'SideKick.ipa'
            with zipfile.ZipFile(ipa, 'w') as archive:
                archive.writestr('Payload/SideStore.app/Info.plist', plistlib.dumps({'CFBundleExecutable': 'SideStore'}))
                archive.writestr('Payload/SideStore.app/SideStore', b'fixture')
            def command(args, **kwargs):
                if args[0] == 'ditto':
                    with zipfile.ZipFile(args[-2]) as archive:
                        archive.extractall(args[-1])
                    return subprocess.CompletedProcess(args, 0)
                self.assertEqual(args[:4], ['codesign', '--display', '--entitlements', ':-'])
                self.assertTrue((Path(args[-1]) / 'SideStore').is_file())
                return subprocess.CompletedProcess(args, 0, stdout=plistlib.dumps(actual))
            for actual in (expected, {}, {GROUP: expected[GROUP]}, {**expected, GROUP: ['group.wrong']}):
                with self.subTest(actual=actual), patch.object(module.subprocess, 'run', side_effect=command):
                    if actual == expected:
                        module.verify(ipa, expected)
                    else:
                        with self.assertRaisesRegex(RuntimeError, 'entitlements'):
                            module.verify(ipa, expected)

    @unittest.skipUnless(shutil.which('swiftc'), 'Behavioral signing fixture requires Swift')
    def test_real_signer_keeps_requested_profile_grants_without_inventing_permissions(self):
        signer = self.signer_source()
        body = re.search(r'            var filteredEntitlements = matchedProfile.entitlements.*?(?=            let plist =)', signer, re.S).group(0)
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'SigningFixture.swift'
            source.write_text('''import Foundation
struct Profile { let entitlements: [String: Any]; let teamIdentifier: String }
struct App { let bundleIdentifier = "com.sidekick.app.TEAM"; let entitlements: [String: Any] }
enum SignerError: Error { case invalidApp(cause: String) }
func verboseLog(_ value: String) {}
func debugLog(_ value: String) {}
func filter(_ app: App, _ matchedProfile: Profile, requiredAppGroups: [String: [String]] = [:]) throws -> [String: Any] {
    BODY
    return filteredEntitlements
}
let group = "com.apple.security.application-groups"
let siri = "com.apple.developer.siri"
let vpn = "com.apple.developer.networking.networkextension"
let profile = Profile(entitlements: [group: ["group.com.sidekick.app.TEAM"], siri: true, vpn: ["packet-tunnel-provider"]], teamIdentifier: "TEAM")
let result = try filter(App(entitlements: [group: ["group.com.sidekick.app"], siri: true]), profile)
precondition(result[group] as? [String] == ["group.com.sidekick.app.TEAM"])
precondition(result[siri] as? Bool == true)
precondition(result[vpn] == nil)
let broken = try filter(App(entitlements: [:]), profile)
precondition(broken[group] == nil) // reproduces the old empty-packaging failure
let repaired = try filter(App(entitlements: [siri: true]), profile, requiredAppGroups: ["com.sidekick.app.TEAM": ["group.com.sidekick.app.TEAM"]])
precondition(repaired[group] as? [String] == ["group.com.sidekick.app.TEAM"])
precondition(repaired[siri] as? Bool == true)
let unrelated = try filter(App(entitlements: [:]), profile, requiredAppGroups: ["another.app": ["group.com.sidekick.app.TEAM"]])
precondition(unrelated[group] == nil)
do {
    _ = try filter(App(entitlements: [:]), profile, requiredAppGroups: ["com.sidekick.app.TEAM": ["group.not.authorized"]])
    preconditionFailure("An unprovisioned group was accepted")
} catch SignerError.invalidApp { }
'''.replace('BODY', body))
            binary = Path(directory) / 'signing-fixture'
            subprocess.run([shutil.which('swiftc'), str(source), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)

    @unittest.skipUnless(sys.platform == 'darwin', 'Actual Mach-O signing requires macOS')
    def test_actual_packaged_ipa_signature_preserves_both_variants(self):
        module = self.module()
        source = plistlib.loads((ROOT / 'SideKickVPN/Host.entitlements').read_bytes())
        source['com.apple.developer.siri'] = True
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / 'Payload/SideStore.app'
            app.mkdir(parents=True)
            shutil.copyfile('/usr/bin/true', app / 'SideStore')
            (app / 'SideStore').chmod(0o755)
            (app / 'Info.plist').write_bytes(plistlib.dumps({
                'CFBundleExecutable': 'SideStore', 'CFBundleIdentifier': 'com.sidekick.app',
                'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
            }))
            for external in (False, True):
                with self.subTest(external_vpn=external):
                    expected = module.requests(source, external_vpn=external)
                    request = root / 'requests.plist'
                    request.write_bytes(plistlib.dumps(expected))
                    subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements', str(request), str(app)], check=True)
                    ipa = root / f'SideKick-{external}.ipa'
                    subprocess.run(['ditto', '-c', '-k', '--keepParent', str(root / 'Payload'), str(ipa)], check=True)
                    module.verify(ipa, expected)


if __name__ == '__main__':
    unittest.main()
