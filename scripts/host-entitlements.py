"""Preserve host permission requests and inspect the final distributed IPA."""
import argparse
from pathlib import Path
import plistlib
import subprocess
import tempfile

GROUP_KEY = 'com.apple.security.application-groups'
VPN_KEYS = ('com.apple.developer.networking.networkextension', 'com.apple.developer.networking.vpn.api')


def requests(configured: dict, *, external_vpn: bool = False) -> dict:
    result = dict(configured)
    if result.get(GROUP_KEY) != ['group.com.sidekick.app']:
        raise ValueError('SideKick must request its App Group before packaging')
    if external_vpn:
        for key in VPN_KEYS:
            result.pop(key, None)
    return result


def verify(ipa: Path, expected: dict) -> None:
    # Inspect the archive users download, rather than trusting the signing input.
    with tempfile.TemporaryDirectory(prefix='sidekick-host-check-') as directory:
        unpacked = Path(directory)
        subprocess.run(['ditto', '-x', '-k', str(ipa), str(unpacked)], check=True)
        apps = list((unpacked / 'Payload').glob('*.app'))
        if len(apps) != 1:
            raise RuntimeError('Expected one main app in the packaged IPA')
        result = subprocess.run(['codesign', '--display', '--entitlements', ':-', str(apps[0])],
                                check=True, stdout=subprocess.PIPE)
        if plistlib.loads(result.stdout) != expected:
            raise RuntimeError(f'{ipa.name}: packaged host entitlements differ from the requested permissions')
    print(f'Verified packaged host entitlements: {ipa.name}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    prepare = commands.add_parser('prepare')
    prepare.add_argument('source', type=Path)
    prepare.add_argument('output', type=Path)
    prepare.add_argument('--external-vpn', action='store_true')
    inspect = commands.add_parser('verify')
    inspect.add_argument('ipa', type=Path)
    inspect.add_argument('expected', type=Path)
    args = parser.parse_args()
    if args.command == 'prepare':
        configured = plistlib.loads(args.source.read_bytes())
        args.output.write_bytes(plistlib.dumps(requests(configured, external_vpn=args.external_vpn)))
    else:
        verify(args.ipa, requests(plistlib.loads(args.expected.read_bytes())))
