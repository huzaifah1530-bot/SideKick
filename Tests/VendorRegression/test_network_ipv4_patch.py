"""Exercise the shipping Darwin address parser without touching dirty vendor sources."""
import io
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class NetworkIPv4PatchTests(unittest.TestCase):
    def test_darwin_netmasks_and_live_loopback(self):
        vendor = ROOT / 'Vendor/SideStore/Dependencies/minimuxer'
        with tempfile.TemporaryDirectory(prefix='sidekick-ipv4-') as tmp:
            target = Path(tmp)
            archive = subprocess.check_output(['git', '-C', str(vendor), 'archive', 'HEAD'])
            with tarfile.open(fileobj=io.BytesIO(archive)) as files:
                files.extractall(target, filter='data')
            subprocess.run(['git', '-C', str(target), 'apply', str(ROOT / 'patches/minimuxer-audit-fixes.patch')], check=True, capture_output=True)
            scanner = target / 'Sources/Services/NetworkIfaceScanner.swift'
            if sys.platform != 'darwin':
                self.skipTest('Darwin sockaddr behavior requires macOS CI')
            parser = target / 'IPv4Parser.swift'
            parser.write_text(scanner.read_text().split('internal struct IP:')[0])
            binary = target / 'ipv4-regression'
            subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', str(parser), str(ROOT / 'Tests/VendorRegression/NetworkIPv4Regression.swift'), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)


if __name__ == '__main__':
    unittest.main()
