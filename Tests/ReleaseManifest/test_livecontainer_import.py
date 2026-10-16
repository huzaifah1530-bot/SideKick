from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class LiveContainerImportIntegrationTests(unittest.TestCase):
    def test_ready_ipa_exposes_handoff_and_repository_metadata_survives_import(self):
        review = (ROOT / 'SideKick/Views/Library/AppManagementView.swift').read_text()
        self.assertIn('LiveContainerImportView(app:', review)
        self.assertIn('Install in LiveContainer', review)
        flow = (ROOT / 'SideKick/Views/LiveContainer/LiveContainerImportView.swift').read_text()
        self.assertIn('LiveContainerIPAActivity', flow)
        self.assertIn('recordLiveContainerImport', flow)
        self.assertIn('rescan(', flow)
        self.assertIn('LiveContainerConnectionsView()', flow)
        importer = (ROOT / 'SideKick/Services/IPAImportStore.swift').read_text()
        self.assertIn('githubImportConfiguration: choice.configuration(', importer)
        native = (ROOT / 'SideKick/Services/SideStoreOperationService.swift').read_text()
        self.assertIn('recordSuccessfulImport(origin, key: key, for: target)', native)
        downloads = (ROOT / 'SideKick/Services/GitHubUpdateDownloadStore.swift').read_text()
        self.assertIn('importConfiguration: importConfiguration', downloads)
        self.assertIn('githubImportConfiguration: importConfiguration', importer)
        environment = (ROOT / 'SideKick/App/AppEnvironment.swift').read_text()
        self.assertIn('reconcileLiveContainerImports(imports, catalogue: liveContainerState)', environment)
        self.assertIn('retained.liveContainerHandoffRequested = retained.githubImportConfiguration != nil', flow)
        self.assertIn('finishLiveContainerHandoff(ipa)', environment)
        self.assertIn('UIApplication.didBecomeActiveNotification', flow)
