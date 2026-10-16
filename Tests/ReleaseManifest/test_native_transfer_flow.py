from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class NativeTransferFlowTests(unittest.TestCase):
    def test_creation_feedback_and_packaging_boundary(self):
        view = (ROOT / 'SideKick/Views/Library/NativeAppTransferView.swift').read_text()
        service = (ROOT / 'SideKick/Services/NativeAppTransferService.swift').read_text()
        self.assertIn('switch page', view)
        self.assertIn('.alert("Transfer could not finish"', view)
        self.assertIn('ProgressView(progressTitle)', view)
        self.assertIn('showShare = true', view)
        self.assertIn('Task.detached(priority: .userInitiated)', service)
        self.assertIn('SideKickStorageCleanup.beginOperation()', service.split('func prepareGuestIPA()')[1].split('func perform(')[0])

    def test_resume_preserves_safety_and_completed_steps(self):
        source = (ROOT / 'SideKick/Views/Library/NativeAppTransferView.swift').read_text()
        self.assertIn('enum NativeTransferPage', source)
        if not shutil.which('swiftc'):
            return
        page = source[source.index('enum NativeTransferPage'):source.index('struct NativeAppTransferView')]
        fixture = '''
@main struct Main {
    static func main() {
        precondition(NativeTransferPage.resume(state: "notStarted", hasFolder: false, verified: false) == .prepare)
        precondition(NativeTransferPage.resume(state: "exported", hasFolder: false, verified: false) == .attach)
        precondition(NativeTransferPage.resume(state: "exported", hasFolder: true, verified: false) == .verify)
        precondition(NativeTransferPage.resume(state: "exported", hasFolder: true, verified: true) == .finish)
        precondition(NativeTransferPage.resume(state: "offloaded", hasFolder: true, verified: true) == .finish)
        for state in ["recoveryNeeded", "exporting", "offloading", "restoring"] {
            precondition(NativeTransferPage.resume(state: state, hasFolder: true, verified: true) == .restore)
        }
        print("Native transfer: resume and recovery gates passed")
    }
}
'''
        with tempfile.TemporaryDirectory(prefix='sidekick-transfer-flow-') as tmp:
            root = Path(tmp)
            (root / 'Page.swift').write_text(page + fixture)
            binary = root / 'flow'
            subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', str(root / 'Page.swift'), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)
