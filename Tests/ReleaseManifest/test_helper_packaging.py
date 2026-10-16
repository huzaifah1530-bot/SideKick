import importlib.util
from pathlib import Path
import plistlib
import subprocess
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[2]


class HelperPackagingTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == 'darwin', 'Actual Mach-O signing requires macOS')
    def test_actual_codesign_preserves_helper_request(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / 'Payload/SideBackup.app'
            app.mkdir(parents=True)
            shutil.copy2('/usr/bin/true', app / 'SideBackup')
            (app / 'Info.plist').write_bytes(plistlib.dumps({
                'CFBundleExecutable': 'SideBackup', 'CFBundleIdentifier': 'com.sidekick.transfer-fixture',
                'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
            }))
            ipa = root / 'SideBackup.ipa'
            subprocess.run(['ditto', '-c', '-k', '--keepParent', str(root / 'Payload'), str(ipa)], check=True)
            subprocess.run([sys.executable, str(ROOT / 'scripts/package-transfer-helper.py'), str(ipa)], check=True)
            unpacked = root / 'verified'
            subprocess.run(['ditto', '-x', '-k', str(ipa), str(unpacked)], check=True)
            result = subprocess.run(['codesign', '--display', '--entitlements', ':-', str(unpacked / 'Payload/SideBackup.app')],
                                    check=True, stdout=subprocess.PIPE)
            self.assertEqual(plistlib.loads(result.stdout)['com.apple.security.application-groups'], ['group.com.sidekick.transfer'])

    def test_workflow_preserves_embedded_helper_group_request_before_both_packages(self):
        workflow = (ROOT / '.github/workflows/ios-build.yml').read_text()
        call = 'python3 scripts/package-transfer-helper.py "$APP_PATH/SideBackup.ipa"'
        self.assertIn(call, workflow)
        self.assertLess(workflow.index(call), workflow.index('cp -R "$APP_PATH" VPNPayload/Payload/'))

    def test_signed_helper_is_verified_and_failed_signing_keeps_original_archive(self):
        script = ROOT / 'scripts/package-transfer-helper.py'
        self.assertTrue(script.exists(), 'Embedded helper packaging step is missing')
        spec = importlib.util.spec_from_file_location('helper_packaging', script)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / 'SideBackup.ipa'
            with zipfile.ZipFile(ipa, 'w') as archive:
                archive.writestr('Payload/SideBackup.app/Info.plist', plistlib.dumps({'CFBundleExecutable': 'SideBackup'}))
                archive.writestr('Payload/SideBackup.app/SideBackup', b'unsigned-fixture')
                archive.writestr('Payload/SideBackup.app/resource.txt', b'keep')
            original = ipa.read_bytes()

            def command(args, **kwargs):
                if args[0] == 'ditto':
                    if '-x' in args:
                        with zipfile.ZipFile(args[-2]) as archive:
                            archive.extractall(args[-1])
                    else:
                        payload = Path(args[-2])
                        with zipfile.ZipFile(args[-1], 'w') as archive:
                            for file in payload.rglob('*'):
                                if file.is_file(): archive.write(file, file.relative_to(payload.parent))
                elif '--entitlements' in args and '--sign' in args:
                    request = plistlib.loads(Path(args[args.index('--entitlements') + 1]).read_bytes())
                    self.assertEqual(request, {module.GROUP_KEY: ['group.com.sidekick.transfer']})
                    binary = Path(args[-1]) / 'SideBackup'
                    binary.write_bytes(b'signed-fixture')
                else:
                    return subprocess.CompletedProcess(args, 0, stdout=plistlib.dumps({module.GROUP_KEY: ['group.com.sidekick.transfer']}))
                return subprocess.CompletedProcess(args, 0, stdout=b'')

            with patch.object(module.subprocess, 'run', side_effect=command):
                module.package(ipa)
            with zipfile.ZipFile(ipa) as archive:
                self.assertEqual(archive.read('Payload/SideBackup.app/SideBackup'), b'signed-fixture')
                self.assertEqual(archive.read('Payload/SideBackup.app/resource.txt'), b'keep')

            ipa.write_bytes(original)
            def missing_signature(args, **kwargs):
                if args[0] == 'codesign' and '--display' in args:
                    return subprocess.CompletedProcess(args, 0, stdout=plistlib.dumps({}))
                return command(args, **kwargs)
            with patch.object(module.subprocess, 'run', side_effect=missing_signature):
                with self.assertRaisesRegex(RuntimeError, 'App Group'):
                    module.package(ipa)
            self.assertEqual(ipa.read_bytes(), original)
            def signing_fails(args, **kwargs):
                if args[0] == 'codesign':
                    raise subprocess.CalledProcessError(1, args)
                return command(args, **kwargs)
            with patch.object(module.subprocess, 'run', side_effect=signing_fails):
                with self.assertRaises(subprocess.CalledProcessError):
                    module.package(ipa)
            self.assertEqual(ipa.read_bytes(), original)


if __name__ == '__main__':
    unittest.main()
