from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[2]

class ImportReviewTests(unittest.TestCase):
    def test_all_import_entry_points_use_package_review(self):
        for name in ['HomeView.swift', 'IPASharingViews.swift', 'ImportDownloadViews.swift']:
            source = (ROOT / 'SideKick/Views/Home' / name).read_text(encoding='utf-8')
            self.assertIn('MatchingIPAImportReviewView(', source)
            self.assertNotIn('Queue this IPA as the update for the installed app?', source)
        review = (ROOT / 'SideKick/Views/Library/MatchingIPAImportReviewView.swift').read_text(encoding='utf-8')
        for choice in ['Queue for Update', 'Install as a Separate App', 'Cancel']:
            self.assertIn(choice, review)
        self.assertIn('onDisappear { if !didFinish { onCancel() } }', review)
        self.assertNotIn('Replace App', review)

    def test_final_install_review_uses_native_lookup_and_can_abort(self):
        source = (ROOT / 'SideKick/Services/NativeInstallReplacementReview.swift').read_text(encoding='utf-8')
        self.assertIn('lookupInstalledAppName(finalIdentifier)', source)
        self.assertIn('InstallReplacementPolicy.replacement', source)
        self.assertIn('guard accepted else { throw OperationError.cancelled }', source)
        self.assertIn('defer { current = previous }', source)
        self.assertNotIn('try? await lookupInstalledAppName', source)
        service = (ROOT / 'SideKick/Services/SideStoreOperationService.swift').read_text(encoding='utf-8')
        self.assertIn('ipa.isUpdateQueued ? ipa.queuedForInstalledAppID : nil', service)

    def test_download_choice_can_save_a_separate_import(self):
        source = (ROOT / 'SideKick/Services/IPAImportDownloadStore.swift').read_text(encoding='utf-8')
        choose = source.split('    func choose(')[1].split('    func retry(')[0]
        self.assertIn('target?.id', choose)
        self.assertIn('isUpdate: target != nil', choose)
        self.assertIn('choicesInFlight', choose)
