"""Exercise the shipping external connection branch without iOS-only dependencies."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class LocalConnectionRegressionTests(unittest.TestCase):
    def test_external_connection_verifies_device_without_requiring_address_hint(self):
        source = (ROOT / 'SideKick/Services/LocalVPNService.swift').read_text(encoding='utf-8')
        self.assertNotIn('NetworkExtension', source, 'The built-in VPN was removed; SideKick uses LocalDevVPN only')
        connect = source.split('    private func connect() async throws {', 1)[1]
        branch = connect.split('    private func prepareDeviceConnection', 1)[0].rsplit('    }', 1)[0]
        acquire = source.split('    private func performAcquire()', 1)[1].split('    func release(', 1)[0]
        self.assertNotIn('externalNotConnected', branch,
                         'An address hint must not block the real paired-device verification')
        self.assertNotIn('externalNotConnected', acquire,
                         'Successful device verification must not be rejected by the same hint afterward')
        if not shutil.which('swiftc'):
            return
        fixture = '''import Foundation
enum ProbeError: Error { case unreachable, unexpectedMode }
@MainActor final class ConnectionProbe {
    let externalConnected = false
    var wasVerified = false
    var failure: ProbeError?
    func prepareDeviceConnection() async throws {
        wasVerified = true
        if let failure { throw failure }
    }
    func connect() async throws {
''' + branch + '''
    }
}
@main struct Main {
    @MainActor static func main() async throws {
        let reachable = ConnectionProbe()
        try await reachable.connect()
        precondition(reachable.wasVerified)
        let unreachable = ConnectionProbe()
        unreachable.failure = .unreachable
        do {
            try await unreachable.connect()
            preconditionFailure("A real connection failure must escape")
        } catch ProbeError.unreachable { }
        precondition(unreachable.wasVerified)
        print("Local connection: missing interface hint permits real verification; failures propagate")
    }
}
'''
        with tempfile.TemporaryDirectory(prefix='sidekick-connection-test-') as tmp:
            path = Path(tmp)
            (path / 'Probe.swift').write_text(fixture)
            binary = path / 'probe'
            subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', str(path / 'Probe.swift'), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)
