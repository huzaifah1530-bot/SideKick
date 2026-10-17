"""Explicit peers must not depend on automatic VPN-interface discovery."""
import io
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ExplicitPeerTests(unittest.TestCase):
    def test_selection_and_shipping_patch_composition(self):
        vendor = ROOT / 'Vendor/SideStore/Dependencies/minimuxer'
        with tempfile.TemporaryDirectory(prefix='sidekick-explicit-peer-') as directory:
            target = Path(directory)
            archive = subprocess.check_output(['git', '-C', str(vendor), 'archive', 'HEAD'])
            with tarfile.open(fileobj=io.BytesIO(archive)) as files:
                files.extractall(target, filter='data')
            for name in ('minimuxer-audit-fixes.patch', 'minimuxer-ipv4-netmask.patch', 'minimuxer-explicit-peer.patch'):
                subprocess.run(['git', '-C', str(target), 'apply', str(ROOT / 'patches' / name)], check=True, capture_output=True)
            observer = (target / 'Sources/Services/NetworkObserverService.swift').read_text(encoding='utf-8')
            manager = (target / 'Sources/Services/DeviceConnectionManager.swift').read_text(encoding='utf-8')
            self.assertIn('if let peer = await manager.effectiveLocalVPNPeer()', observer)
            self.assertNotIn('let effectiveIp = await isOverridden', observer)
            method = re.search(r'    func effectiveLocalVPNPeer\(\) -> String\? \{.*?^    \}', manager, re.S | re.M).group(0)
            self.assertIn('return isOverridePeerIpReachable ? peer : nil', method)
            workflow = (ROOT / '.github/workflows/ios-build.yml').read_text()
            self.assertLess(workflow.index('patches/minimuxer-ipv4-netmask.patch'), workflow.index('patches/minimuxer-explicit-peer.patch'))
            compiler = shutil.which('swiftc')
            if not compiler:
                self.skipTest('Swift peer-selection fixture requires macOS CI')
            fixture = '''struct Snapshot {
    var overridePeerIp: String?
    var isOverridePeerIpReachable = false
    var vpnIface: Bool? = nil
    var isDerivedPeerIpReachable = false
    var derivedPeerIp: String? = nil
    METHOD
}
// An explicit IPv4/IPv6 peer remains selectable without a discovered candidate.
for peer in ["100.64.0.2", "fd7a:115c:a1e0::2", "fe80::2%utun3"] {
    let value = Snapshot(overridePeerIp: peer, isOverridePeerIpReachable: true)
    precondition(value.effectiveLocalVPNPeer() == peer)
}
// Retain explicit intent when stale/unreachable, even if another device responds.
var state = Snapshot(overridePeerIp: "100.64.0.2", vpnIface: true, isDerivedPeerIpReachable: true, derivedPeerIp: "10.7.0.1")
precondition(state.effectiveLocalVPNPeer() == nil)
state.isOverridePeerIpReachable = true
precondition(state.effectiveLocalVPNPeer() == "100.64.0.2")
state.isOverridePeerIpReachable = false
precondition(state.effectiveLocalVPNPeer() == nil) // disconnect/network change
state.overridePeerIp = nil
precondition(state.effectiveLocalVPNPeer() == "10.7.0.1")
state.overridePeerIp = ""
precondition(state.effectiveLocalVPNPeer() == "10.7.0.1")
state.vpnIface = nil
precondition(state.effectiveLocalVPNPeer() == nil)
state.vpnIface = true
state.isDerivedPeerIpReachable = false
precondition(state.effectiveLocalVPNPeer() == nil)
'''.replace('METHOD', method)
            source = target / 'PeerSelectionFixture.swift'
            source.write_text(fixture, encoding='utf-8')
            binary = target / 'peer-selection-fixture'
            subprocess.run([compiler, str(source), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)
            subprocess.run([compiler, '-frontend', '-parse', str(target / 'Sources/Services/NetworkObserverService.swift')], check=True)
