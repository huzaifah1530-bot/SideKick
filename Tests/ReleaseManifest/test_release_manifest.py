"""Release validation uses the integrated xcconfig, including conditional keys."""
import importlib.util
import json
import os
import plistlib
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[2] / "scripts/create-release-manifest.py"
spec = importlib.util.spec_from_file_location("release_manifest", SCRIPT)
manifest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manifest)


class ReleaseManifestTests(unittest.TestCase):
    def test_conditional_build_settings_preserve_configuration_selector(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "Build.xcconfig"
            config.write_text(
                "MAIN_BUNDLE_IDENTIFIER[config=Release] = $(BASE_BUNDLE_ID)\n"
                "MAIN_BUNDLE_IDENTIFIER[config=Debug]=$(BASE_BUNDLE_ID).dev\n",
                encoding="utf-8",
            )
            settings = manifest.parse_xcconfig(config)
            self.assertEqual(settings["MAIN_BUNDLE_IDENTIFIER[config=Release]"], "$(BASE_BUNDLE_ID)")
            self.assertEqual(settings["MAIN_BUNDLE_IDENTIFIER[config=Debug]"], "$(BASE_BUNDLE_ID).dev")

    def test_valid_integrated_packages_generate_manifest_and_wrong_build_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "Build.xcconfig"
            config.write_text(
                "MARKETING_VERSION = 0.8.0\nCURRENT_PROJECT_VERSION = 0800\n"
                "ORG_IDENTIFIER = com.sidekick\nBASE_BUNDLE_ID = $(ORG_IDENTIFIER).app\n"
                "MAIN_BUNDLE_IDENTIFIER[config=Release] = $(BASE_BUNDLE_ID)\n",
                encoding="utf-8",
            )
            packages = {"standard": root / "standard.ipa", "vpn": root / "vpn.ipa"}
            info = {"CFBundleIdentifier": "com.sidekick.app", "CFBundleShortVersionString": "0.8.0", "CFBundleVersion": "42"}
            for ipa in packages.values():
                with zipfile.ZipFile(ipa, "w") as archive:
                    archive.writestr("Payload/SideStore.app/Info.plist", plistlib.dumps(info))
            source = root / "source.tar.gz"
            source.write_bytes(b"fixture source archive")
            output = root / "manifest.json"
            with patch.multiple(manifest, ROOT=root, ARTIFACTS=root, BUILD_CONFIG=config,
                                IPA_PATHS=packages, SOURCE_PATH=source, MANIFEST_PATH=output), \
                 patch.dict(os.environ, {"GITHUB_RUN_NUMBER": "42"}), \
                 patch.object(manifest.subprocess, "check_output", return_value="fixture-commit\n"):
                manifest.main()
                result = json.loads(output.read_text(encoding="utf-8"))
                self.assertEqual(result["app"]["buildNumber"], "42")
                self.assertEqual(result["run"]["sideStoreCommit"], "fixture-commit")
                self.assertEqual(result["packages"]["standardIPA"]["sha256"], manifest.sha256(packages["standard"]))
                with patch.dict(os.environ, {"GITHUB_RUN_NUMBER": "43"}):
                    with self.assertRaisesRegex(SystemExit, "does not match integrated build"):
                        manifest.main()


if __name__ == "__main__":
    unittest.main()
