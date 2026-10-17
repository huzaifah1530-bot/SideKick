"""Check the CI patch sequence against the pinned vendor revision, without editing it."""
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PATCHES = [
    "sidestore-sidekick.patch",
    "sidestore-certificate-error-classification.patch",
    "sidestore-use-account-certificate-for-refresh.patch",
    "sidestore-compiler-workarounds.patch",
    "sidestore-view-body-compile.patch",
]


class IntegrationPatchTests(unittest.TestCase):
    def test_ci_patch_sequence_and_integrated_bootstrap(self):
        with tempfile.TemporaryDirectory(prefix="sidekick-patch-check-") as directory:
            checkout = Path(directory)
            subprocess.run(["git", "init", "--quiet", str(checkout)], check=True)
            paths = set()
            audit_patch = (ROOT / "patches/sidestore-audit-fixes.patch").read_text(encoding="utf-8")
            paths.update(path.rstrip("\t\r") for path in re.findall(r"^--- a/(.+)$", audit_patch, re.M))
            paths.update([
                "SideBackup/SideBackupApp.swift", "SideStore/Core/Operations/PipelineOperations/StageBackupAppOperation.swift",
                "SideBackup/ContentView.swift", "SideBackup/ConsoleLog.swift",
                "Shared/Extensions/Bundle+AltStore.swift", "SideStore/Core/Operations/PipelineExecutor.swift",
                "SideStore/Core/Operations/PipelineOperations/FetchProvisioningProfilesOperation.swift",
                "SideStore/Core/Operations/PipelineOperations/ResignAppOperation.swift",
                "SideStore/Core/Operations/PipelineOperations/RemoveBackupDataOperation.swift",
                "AltWidget/Info.plist", "SideBackup/Info.plist",
                "AltStore/Resources/ReleaseEntitlements.plist",
                "SideStore/Core/Operations/PipelineOperations/RemoveAppExtensionsOperation.swift",
                "SideStore/MaintenanceManager.swift", "SideStore/Utils/iostreams/ConsoleLog.swift",
                "SideStore/Utils/common/FileOutputStream.swift",
                "SideStore/Core/Anisette/AnisetteProvider.swift",
                "SideStore/Core/Anisette/OnDeviceAnisetteManager.swift",
                "SideStore/Core/Operations/StandaloneOperations/SignInOperation.swift",
            ])
            for patch in PATCHES:
                content = (ROOT / "patches" / patch).read_text(encoding="utf-8")
                paths.update(path.rstrip("\t\r") for path in re.findall(r"^--- a/(.+)$", content, re.M))
                # macOS CI checks out LF; Windows core.autocrlf may give us CRLF.
                (checkout / patch).write_bytes(content.encode("utf-8"))
            for path in paths:
                content = subprocess.check_output([
                    "git", "-C", str(ROOT / "Vendor/SideStore"), "show", "HEAD:" + path,
                ])
                target = checkout / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(content)
            for patch in PATCHES:
                command = ["git", "-C", str(checkout), "apply"]
                if patch in PATCHES[1:3]:
                    command.append("--unidiff-zero")
                result = subprocess.run(command + [str(checkout / patch)], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, f"{patch}: {result.stderr}")

            import sys
            result = subprocess.run([sys.executable, str(ROOT / "scripts/embed-local-vpn.py"), str(checkout)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            patch_path = checkout / "audit.patch"
            patch_path.write_bytes(audit_patch.encode("utf-8"))
            result = subprocess.run(["git", "-C", str(checkout), "apply", str(patch_path)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            for name in ("sidestore-anisette-recovery.patch", "sidestore-diagnostics.patch"):
                patch_path.write_bytes((ROOT / "patches" / name).read_text(encoding="utf-8").encode("utf-8"))
                result = subprocess.run(["git", "-C", str(checkout), "apply", str(patch_path)], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, f"{name}: {result.stderr}")
            if compiler := shutil.which("swiftc"):
                for relative in ("SideStore/Core/Anisette/AnisetteProvider.swift", "SideStore/Core/Operations/StandaloneOperations/SignInOperation.swift"):
                    subprocess.run([compiler, "-frontend", "-parse", str(checkout / relative)], check=True)
            result = subprocess.run([sys.executable, str(ROOT / "scripts/integrate-backup-helper.py"), str(checkout)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            stage = (checkout / "SideStore/Core/Operations/PipelineOperations/StageBackupAppOperation.swift").read_text()
            self.assertIn('updates["SideKickBackupAppGroup"] = backupGroup', stage)
            shared = (checkout / "Shared/Extensions/Bundle+AltStore.swift").read_text()
            self.assertIn('return self.appGroups.contains(expected) ? expected : nil', shared)
            provisioning = (checkout / "SideStore/Core/Operations/PipelineOperations/FetchProvisioningProfilesOperation.swift").read_text()
            self.assertIn('targetAppBundle.infoPlist["SideKickBackupAppGroup"] as? String == groupIdentifier', provisioning)
            self.assertIn('Bundle.main.appGroups.contains(groupIdentifier)', provisioning)
            self.assertLess(provisioning.index('return groupIdentifier'), provisioning.index('return groupIdentifier + "." + team.identifier'))
            signing = (checkout / "SideStore/Core/Operations/PipelineOperations/ResignAppOperation.swift").read_text()
            self.assertIn('resignedAppBundle.executableName == "SideBackup"', signing)
            self.assertIn(').contains(expected)', signing)
            helper = (checkout / "SideBackup/ContentView.swift").read_text()
            self.assertNotIn('Color("Background")', helper)
            self.assertIn('Activity Log', helper)
            self.assertIn('SideKick', helper)
            if compiler := shutil.which("swiftc"):
                for relative in ["SideBackup/ContentView.swift", "Shared/Extensions/Bundle+AltStore.swift",
                                 "SideStore/Core/Operations/PipelineExecutor.swift",
                                 "SideStore/Core/Operations/PipelineOperations/StageBackupAppOperation.swift",
                                 "SideStore/Core/Operations/PipelineOperations/FetchProvisioningProfilesOperation.swift",
                                 "SideStore/Core/Operations/PipelineOperations/ResignAppOperation.swift",
                                 "AltStore/Managing Apps/AppManager.swift"]:
                    subprocess.run([compiler, "-frontend", "-parse", str(checkout / relative)], check=True)
                # Exercise the actual composed resolver with different host/helper IDs.
                getter = re.search(r'@objc dynamic var altstoreAppGroup: String\? \{.*?\n    \}', shared, re.S).group(0)
                fixture = '''import Foundation
enum Bundle { static let baseAltStoreAppGroupID = "group.com.spotify.client.TEAM" }
struct FakeBundle {
    let appGroups: [String]
    let expected: String?
    func object(forInfoDictionaryKey: String) -> Any? { expected }
    GETTER
}
let host = "group.com.sidekick.app.TEAM"
precondition(FakeBundle(appGroups: [host], expected: host).altstoreAppGroup == host)
precondition(FakeBundle(appGroups: [host + ".TEAM"], expected: host).altstoreAppGroup == nil)
precondition(FakeBundle(appGroups: [Bundle.baseAltStoreAppGroupID], expected: host).altstoreAppGroup == nil)
precondition(FakeBundle(appGroups: [Bundle.baseAltStoreAppGroupID], expected: nil).altstoreAppGroup == Bundle.baseAltStoreAppGroupID)
'''.replace('GETTER', getter.replace('@objc dynamic ', ''))
                source = checkout / "BackupGroupFixture.swift"
                source.write_text(fixture)
                binary = checkout / "backup-group-fixture"
                subprocess.run([compiler, str(source), "-o", str(binary)], check=True)
                subprocess.run([str(binary)], check=True)
            for relative, patch_name in [
                ("Dependencies/SideSign", "sidesign-audit-fixes.patch"),
                ("Dependencies/minimuxer", "minimuxer-audit-fixes.patch"),
            ]:
                dependency = checkout / relative
                dependency.mkdir(parents=True, exist_ok=True)
                subprocess.run(["git", "init", "--quiet", str(dependency)], check=True)
                content = (ROOT / "patches" / patch_name).read_text(encoding="utf-8")
                paths = re.findall(r"^--- a/(.+)$", content, re.M)
                for path in paths:
                    path = path.rstrip("\t\r")
                    target = dependency / path
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(subprocess.check_output(["git", "-C", str(ROOT / "Vendor/SideStore" / relative), "show", "HEAD:" + path]))
                patch_path.write_bytes(content.encode("utf-8"))
                result = subprocess.run(["git", "-C", str(dependency), "apply", str(patch_path)], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
            delegate = (checkout / "AltStore/AppDelegate.swift").read_text(encoding="utf-8")
            begin = delegate.index("private func prepareForBackgroundFetch()")
            end = delegate.index("\n    }", begin)
            self.assertNotIn("requestAuthorization", delegate[begin:end])
            self.assertIn("GitHubUpdateNotificationRouteStore.recordTap", delegate)
            self.assertIn("try SideKickDataDirectory.prepareBeforeDatabaseStart()", delegate)
            self.assertIn("MARKETING_VERSION = 0.9.0", (checkout / "Build.xcconfig").read_text(encoding="utf-8"))
            project = (checkout / "AltStore.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
            self.assertIn("App/SideKickApp.swift,", project)
            self.assertIn("path = ../../SideKick;", project)


if __name__ == "__main__":
    unittest.main()
