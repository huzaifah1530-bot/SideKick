from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

class UnsavedSettingsIntegrationTests(unittest.TestCase):
    def test_explicit_save_pages_and_tab_navigation_are_guarded(self):
        pages = (ROOT / 'SideKick/Views/Settings/SideStoreSettingsPages.swift').read_text(encoding='utf-8')
        tokens = (ROOT / 'SideKick/Views/Settings/GitHubAccountSettingsView.swift').read_text(encoding='utf-8')
        root = (ROOT / 'SideKick/Views/Root/ContentView.swift').read_text(encoding='utf-8')
        self.assertEqual(pages.count('.guardUnsavedSettings('), 2)
        self.assertIn('.guardUnsavedSettings(', tokens)
        self.assertIn('unsavedSettings.requestNavigation', root)
        self.assertIn('.keyboardShortcut(.defaultAction)', root)
        self.assertIn('Button("Don’t Save")', root)
        self.assertNotIn('Button("Don’t Save", role:', root)
