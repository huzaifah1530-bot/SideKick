from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class InstallStartTests(unittest.TestCase):
    def test_confirmation_is_visible_and_does_not_depend_on_alert_presentation(self):
        source = (ROOT / 'SideKick/Views/Library/AppManagementView.swift').read_text()
        console = source[source.index('struct InstallConsoleView:'):]
        self.assertIn('if startState == .awaitingConfirmation', console)
        self.assertIn('Ready to Update', console)
        self.assertIn('startState.confirm()', console)
        self.assertNotIn('showingInstallConfirmation', console)
        self.assertIn('guard startState.begin() else { return }', console)

    def test_confirmation_and_duplicate_start_gate(self):
        source = (ROOT / 'SideKick/Views/Library/AppManagementView.swift').read_text()
        self.assertIn('enum InstallStartState', source)
        if not shutil.which('swiftc'):
            return
        state = source[source.index('enum InstallStartState'):source.index('struct InstallConsoleView:')]
        fixture = '''
@main struct Main {
    static func main() {
        var confirmed = InstallStartState(requiresConfirmation: true)
        precondition(!confirmed.begin())
        confirmed.confirm()
        precondition(confirmed.begin())
        precondition(!confirmed.begin())
        confirmed.confirm()
        precondition(!confirmed.begin())
        var automatic = InstallStartState(requiresConfirmation: false)
        precondition(automatic.begin())
        automatic = .finished
        precondition(!automatic.begin())
        automatic = .ready
        precondition(automatic.begin())
        print("Install start: confirmation, automatic, duplicate and retry gates passed")
    }
}
'''
        with tempfile.TemporaryDirectory(prefix='sidekick-install-start-') as tmp:
            path = Path(tmp)
            (path / 'Start.swift').write_text(state + fixture)
            binary = path / 'start'
            subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', str(path / 'Start.swift'), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)
