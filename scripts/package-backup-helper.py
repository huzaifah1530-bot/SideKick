"""Preserve the normal SideBackup App Group request before on-device re-signing.

The placeholder below requests the entitlement key, not permission to access a
container. SideSign replaces its values with the target's provisioned groups.
"""
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

GROUP_KEY = 'com.apple.security.application-groups'


def package(ipa: Path) -> None:
    # Keep the original archive intact unless signing and inspection both pass.
    with tempfile.TemporaryDirectory(prefix='sidekick-helper-', dir=ipa.parent) as directory:
        root = Path(directory)
        unpacked = root / 'unpacked'
        subprocess.run(['ditto', '-x', '-k', str(ipa), str(unpacked)], check=True)
        helper = unpacked / 'Payload/SideBackup.app'
        info = plistlib.loads((helper / 'Info.plist').read_bytes())
        if info.get('CFBundleExecutable') != 'SideBackup':
            raise RuntimeError('Unexpected SideBackup executable')
        entitlements = root / 'requests.plist'
        request = {GROUP_KEY: ['group.com.sidekick.transfer']}
        entitlements.write_bytes(plistlib.dumps(request))
        subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements', str(entitlements), str(helper)], check=True)
        inspected = subprocess.run(['codesign', '--display', '--entitlements', ':-', str(helper)],
                                   check=True, stdout=subprocess.PIPE)
        if plistlib.loads(inspected.stdout).get(GROUP_KEY) != request[GROUP_KEY]:
            raise RuntimeError('Embedded helper lost its App Group entitlement request')
        output = root / 'SideBackup.ipa'
        subprocess.run(['ditto', '-c', '-k', '--keepParent', str(unpacked / 'Payload'), str(output)], check=True)
        output.replace(ipa)


if __name__ == '__main__':
    package(Path(sys.argv[1]).resolve())
