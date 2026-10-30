from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[2]

class SignerExportTests(unittest.TestCase):
    def test_export_uses_installed_signer_without_switching_the_active_certificate(self):
        source = (ROOT / 'SideKick/Services/SigningAccountStore.swift').read_text(encoding='utf-8')
        export = source.split('    func liveContainerCertificateForExport(')[1].split('    nonisolated private static func')[0]
        self.assertIn('CertificateExportPolicy.validate', export)
        self.assertIn('getSigningCertificate(for: liveContainer)', export)
        self.assertNotIn('assignedSigningCertificate', export)
        self.assertNotIn('setActiveCertificate', export)
        self.assertIn('OCSPValidator.validate', export)
        self.assertLess(export.index('CertificateExportPolicy.validate'), export.index('CertificateManager.convert'))
        recipients = source.split('    func liveContainerCertificateRecipients()')[1].split('    /// Capture the selected')[0]
        self.assertIn('signingCertificateSerial: serial, certificateName: imported.name', recipients)

    def test_account_import_action_is_in_plus_menu(self):
        source = (ROOT / 'SideKick/Views/Accounts/AccountsView.swift').read_text(encoding='utf-8')
        self.assertNotIn('Import or Manage Certificates', source)
        menu = source.split('        .toolbar {')[1].split('        .task {')[0]
        self.assertIn('Label("Certificate"', menu)
        self.assertIn('ImportedCertificatesView()', menu)
