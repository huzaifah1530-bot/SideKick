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
            result = subprocess.run([sys.executable, str(ROOT / "scripts/embed-file-transfer.py"), str(checkout)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            helper = (checkout / "SideBackup/SideBackupApp.swift").read_text(encoding="utf-8")
            self.assertIn("enum AppDataTransfer", helper)
            self.assertIn("performSideKickFileTransfer(restoring: true)", helper)
            stage = (checkout / "SideStore/Core/Operations/PipelineOperations/StageBackupAppOperation.swift").read_text(encoding="utf-8")
            self.assertIn('updates["CFBundleVersion"] = targetApp.buildVersion', stage)
            if compiler := shutil.which("swiftc"):
                parsed = subprocess.run([compiler, "-frontend", "-parse", str(checkout / "SideBackup/SideBackupApp.swift")], capture_output=True, text=True)
                self.assertEqual(parsed.returncode, 0, parsed.stderr)
            for relative, patch_name in [
                ("Dependencies/SideSign", "sidesign-audit-fixes.patch"),
                ("Dependencies/minimuxer", "minimuxer-audit-fixes.patch"),
            ]:
                dependency = checkout / relative
                dependency.mkdir(parents=True, exist_ok=True)
                subprocess.run(["git", "init", "--quiet", str(dependency)], check=True)
                content = (ROOT / "patches" / patch_name).read_text(encoding="utf-8")
                for path in re.findall(r"^--- a/(.+)$", content, re.M):
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
            self.assertIn("MARKETING_VERSION = 0.8.0", (checkout / "Build.xcconfig").read_text(encoding="utf-8"))
            project = (checkout / "AltStore.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
            self.assertIn("App/SideKickApp.swift,", project)
            self.assertIn("path = ../../SideKick;", project)


if __name__ == "__main__":
    unittest.main()
