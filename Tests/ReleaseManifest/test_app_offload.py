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
        self.assertIn('let recoverBinary = restoring && !hasBackup && !knownOffload', service)
        self.assertIn('if restoring && knownOffload && !hasBackup', service)
        self.assertNotIn('SideKickFileTransferRequest', service)
        self.assertNotIn('SideKickCredentialTransferRequest', service)
        self.assertNotIn('embed-file-transfer.py', workflow)
        self.assertNotIn('embed-credential-transfer.py', workflow)
        self.assertIn('AppOffloadConsoleView(', view)
        self.assertIn('if succeeded && offloaded { offerLiveContainer = true }', view)
        self.assertIn('OperationStatusView(', view)
        self.assertIn('progressHandler:', view)
        self.assertIn('stageHandler:', view)
        self.assertIn('group.progress.observe', service)
        self.assertIn('scripts/integrate-backup-helper.py', workflow)
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
        self.assertIn('ForEach(installedApps.filter { !$0.isActive })', home)
        self.assertIn('NavigationLink { AppManagementView(installedApp: app) }', home)
        detail = (ROOT / 'SideKick/Views/Library/AppManagementView.swift').read_text(encoding='utf-8')
        self.assertIn('Label("Restore App"', detail)
        self.assertIn('Button("Remove from Saved"', detail)
        self.assertNotIn('Button("Remove from Saved"', home)
        self.assertIn('$0.isActive && !AppOffloadService.blocksNativeOperations', runtime)
        self.assertIn('SideKick.transfer.', service)  # Retain interrupted old-transfer recovery.
        self.assertIn('importConfiguration: configuration', service)
        self.assertIn('queuedForUpdate: false', service)
        self.assertIn('guard !installed.isActive', service)
        self.assertFalse((ROOT / 'SideKick/Views/Library/NativeAppTransferView.swift').exists())
        self.assertFalse((ROOT / 'SideKick/Services/SystemAppCredentialStore.swift').exists())
