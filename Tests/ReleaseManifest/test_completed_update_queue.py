from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class CompletedQueueIntegrationTests(unittest.TestCase):
    def test_shared_install_and_verified_self_launch_both_clear_queue(self):
        source = (ROOT / 'SideKick/Services/SideStoreOperationService.swift').read_text()
        loading = source.split('func loadInstalledApps(', 1)[1].split('    func install(', 1)[0]
        installing = source.split('    private func performInstall(', 1)[1].split('    func refresh(', 1)[0]
        self.assertIn('removeInstalledSelfUpdates', loading)
        self.assertIn('if selfBinaryMatches', installing)
        self.assertIn('try await ipaStore.delete(ipa)', installing)
        self.assertLess(installing.index('installedID = try await'), installing.index('try await ipaStore.delete(ipa)'))
