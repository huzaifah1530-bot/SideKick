#!/usr/bin/env python3
"""Validate the integrated CI IPA and identify it with its matching source."""

from __future__ import annotations

import hashlib
import json
import os
import plistlib
import re
import subprocess
import zipfile
from pathlib import Path
from typing import NoReturn


ROOT = Path(__file__).resolve().parent.parent
ARTIFACTS = ROOT / "artifacts"
BUILD_CONFIG = ROOT / "Vendor/SideStore/Build.xcconfig"
IPA_PATHS = {
    "standard": ARTIFACTS / "SideKick-unsigned.ipa",
}
SOURCE_PATH = ARTIFACTS / "SideKick-corresponding-source.tar.gz"
MANIFEST_PATH = ARTIFACTS / "SideKick-release-manifest.json"


def fail(message: str) -> NoReturn:
    raise SystemExit(f"Release manifest error: {message}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_xcconfig(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        # Selectors contain '=' themselves (for example [config=Release]);
        # only the assignment outside those brackets separates key and value.
        match = re.match(r"^([^\s=\[]+(?:\[[^\]]+\])*)\s*=\s*(.*?)\s*$", line)
        if match:
            values[match.group(1)] = match.group(2)
    return values


def packaged_app_metadata(ipa_path: Path) -> dict[str, str]:
    try:
        with zipfile.ZipFile(ipa_path) as archive:
            info = plistlib.loads(archive.read("Payload/SideStore.app/Info.plist"))
    except (OSError, KeyError, ValueError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        fail(f"cannot read SideStore app metadata from {ipa_path.name}: {error}")
    if not isinstance(info, dict):
        fail(f"app metadata in {ipa_path.name} is not a property-list dictionary")

    return {
        "bundleIdentifier": str(info.get("CFBundleIdentifier", "")),
        "marketingVersion": str(info.get("CFBundleShortVersionString", "")),
        "buildNumber": str(info.get("CFBundleVersion", "")),
    }


def artifact_record(path: Path) -> dict[str, str]:
    if not path.is_file():
        fail(f"required artifact is missing: {path.name}")
    return {"file": path.name, "sha256": sha256(path)}


def main() -> None:
    config = parse_xcconfig(BUILD_CONFIG)
    required_config = (
        "MARKETING_VERSION",
        "CURRENT_PROJECT_VERSION",
        "ORG_IDENTIFIER",
        "BASE_BUNDLE_ID",
        "MAIN_BUNDLE_IDENTIFIER[config=Release]",
    )
    missing = [key for key in required_config if key not in config]
    if missing:
        fail(f"integrated Build.xcconfig is missing {', '.join(missing)}")

    if config["BASE_BUNDLE_ID"] != "$(ORG_IDENTIFIER).app":
        fail("integrated release base bundle ID expression changed; update release validation")
    if config["MAIN_BUNDLE_IDENTIFIER[config=Release]"] != "$(BASE_BUNDLE_ID)":
        fail("integrated Release bundle ID expression changed; update release validation")

    expected_metadata = {
        "bundleIdentifier": f"{config['ORG_IDENTIFIER']}.app",
        "marketingVersion": config["MARKETING_VERSION"],
        # ios-build.yml overrides this setting to the Actions run number.
        "buildNumber": os.environ.get("GITHUB_RUN_NUMBER", ""),
    }
    if not expected_metadata["buildNumber"]:
        fail("GITHUB_RUN_NUMBER is required to identify the integrated build")

    app_metadata: dict[str, str] | None = None
    for path in IPA_PATHS.values():
        metadata = packaged_app_metadata(path)
        if metadata != expected_metadata:
            fail(
                f"{path.name} metadata {metadata} does not match integrated build "
                f"configuration {expected_metadata}"
            )
        if app_metadata is None:
            app_metadata = metadata

    assert app_metadata is not None
    try:
        side_store_commit = subprocess.check_output(
            ["git", "-C", str(ROOT / "Vendor/SideStore"), "rev-parse", "HEAD"],
            text=True,
        ).strip()
    except (OSError, subprocess.CalledProcessError) as error:
        fail(f"cannot identify the SideStore source revision: {error}")

    manifest = {
        "manifestVersion": 1,
        "artifactKind": "integrated-ci-build",
        "run": {
            "repository": os.environ.get("GITHUB_REPOSITORY", ""),
            "workflow": os.environ.get("GITHUB_WORKFLOW", ""),
            "runId": os.environ.get("GITHUB_RUN_ID", ""),
            "runAttempt": os.environ.get("GITHUB_RUN_ATTEMPT", ""),
            "runNumber": expected_metadata["buildNumber"],
            "ref": os.environ.get("GITHUB_REF", ""),
            "commit": os.environ.get("GITHUB_SHA", ""),
            "sideStoreCommit": side_store_commit,
        },
        "app": app_metadata,
        "integratedBuildConfig": {
            "file": "Vendor/SideStore/Build.xcconfig",
            "sha256": sha256(BUILD_CONFIG),
        },
        "packages": {
            "standardIPA": artifact_record(IPA_PATHS["standard"]),
            "correspondingSource": artifact_record(SOURCE_PATH),
        },
    }
    MANIFEST_PATH.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(f"Validated and wrote {MANIFEST_PATH.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
