from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class AppOffloadTests(unittest.TestCase):
    def test_shipping_uses_normal_backup_and_prompts_only_after_success(self):
        service = (ROOT / 'SideKick/Services/AppOffloadService.swift').read_text()
        view = (ROOT / 'SideKick/Views/Library/AppOffloadView.swift').read_text()
        workflow = (ROOT / '.github/workflows/ios-build.yml').read_text()
        self.assertIn('AppManager.shared.deactivate(', service)
        self.assertIn('AppManager.shared.activate(', service)
        self.assertIn('AppManager.shared.restore(', service)
        self.assertIn('(installed.isActive && !hasBackup)', service)
        self.assertNotIn('SideKickFileTransferRequest', service)
        self.assertNotIn('SideKickCredentialTransferRequest', service)
        self.assertNotIn('embed-file-transfer.py', workflow)
        self.assertNotIn('embed-credential-transfer.py', workflow)
        operation = view.split('private func run(restoring: Bool)')[1].split('private func prepareIPA()')[0]
        self.assertLess(operation.index('try await service.perform'), operation.index('offerLiveContainer = true'))
        self.assertIn('if !restoring && offloaded', operation)
        self.assertGreater(operation.index('catch'), operation.index('offerLiveContainer = true'))
        # Native data backup must complete before upstream removes the installation.
        import subprocess
        pipeline = subprocess.check_output(['git', '-C', str(ROOT / 'Vendor/SideStore'), 'show',
            'HEAD:SideStore/Core/Operations/OperationStepDefinition.swift'], text=True)
        deactivate = pipeline.split('static let deactivate:')[1].split('static let backup:')[0]
        self.assertLess(deactivate.index('.backupAppData'), deactivate.index('.uninstallApp'))
        self.assertLess(deactivate.index('.uninstallApp'), deactivate.index('.markAppInactive'))

    def test_inactive_apps_remain_restorable_and_are_not_refreshed(self):
        home = (ROOT / 'SideKick/Views/Home/HomeView.swift').read_text()
        runtime = (ROOT / 'SideKick/Services/SideStoreOperationService.swift').read_text()
        service = (ROOT / 'SideKick/Services/AppOffloadService.swift').read_text()
        self.assertIn('SwiftUI.Section("Offloaded")', home)
        self.assertIn('$0.isActive && !AppOffloadService.blocksNativeOperations', runtime)
        self.assertIn('SideKick.transfer.', service)  # Retain interrupted old-transfer recovery.
        self.assertIn('importConfiguration: configuration', service)
        self.assertIn('queuedForUpdate: false', service)
        self.assertIn('guard !installed.isActive', service)
        self.assertFalse((ROOT / 'SideKick/Views/Library/NativeAppTransferView.swift').exists())
        self.assertFalse((ROOT / 'SideKick/Services/SystemAppCredentialStore.swift').exists())
