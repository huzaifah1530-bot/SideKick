"""The restore helper retains the exact host group after its old signature is removed."""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class RestoreHelperSigningTests(unittest.TestCase):
    def test_production_helper_request_is_scoped_and_profile_authorized(self):
        patch = (ROOT / 'patches/sidestore-signing-repairs.patch').read_text(encoding='utf-8')
        production = '\n'.join(line[1:] for line in patch.splitlines() if line.startswith('+') and not line.startswith('+++'))
        match = re.search(r'        if let app = ALTApplication\(fileURL: fileURL\), app.executableName == "SideBackup" \{.*?\n        \}', production, re.S)
        self.assertIsNotNone(match, 'Restore helpers must explicitly request their authorized host group before signing')
        body = match.group(0)
        self.assertIn('expected == Bundle.main.altstoreAppGroup', body)
        self.assertIn('grants.contains(expected)', body)
        self.assertIn('requiredAppGroups[app.bundleIdentifier] = [expected]', body)
        compiler = shutil.which('swiftc')
        if not compiler:
            self.skipTest('Behavioral Swift fixture runs in macOS CI')
        source = '''import Foundation
enum OperationError: Error { case invalidParameters(String) }
extension String { static let appGroups = "groups" }
struct Profile { let bundleIdentifier: String; let entitlements: [String: Any] }
struct ALTApplication {
    static var current: ALTApplication? = nil
    let executableName: String
    let bundleIdentifier: String
    let infoPlist: [String: Any]
    init(_ name: String, _ id: String, _ info: [String: Any]) { executableName = name; bundleIdentifier = id; infoPlist = info }
    init?(fileURL: URL) { guard let app = Self.current else { return nil }; self = app }
}
enum Bundle { static let main = Host(); struct Host { let altstoreAppGroup: String? = "group.com.sidekick.app.TEAM" } }
func required(_ profiles: [Profile]) throws -> [String: [String]] {
    let fileURL = URL(fileURLWithPath: "/App.app")
    var requiredAppGroups: [String: [String]] = [:]
    BODY
    return requiredAppGroups
}
let group = "group.com.sidekick.app.TEAM"
let id = "com.spotify.client.TEAM"
let profile = Profile(bundleIdentifier: id, entitlements: [.appGroups: [group]])
// The prepared helper has no source signature/entitlements; its staged metadata survives.
ALTApplication.current = ALTApplication("SideBackup", id, ["SideKickBackupAppGroup": group])
let repaired = try required([profile])
precondition(repaired == [id: [group]])
for profiles in [[], [Profile(bundleIdentifier: "another.app", entitlements: [.appGroups: [group]])], [Profile(bundleIdentifier: id, entitlements: [:])]] {
    do { _ = try required(profiles); preconditionFailure("Missing grant accepted") } catch OperationError.invalidParameters { }
}
for metadata in [[:], ["SideKickBackupAppGroup": "group.other"]] {
    ALTApplication.current = ALTApplication("SideBackup", id, metadata)
    do { _ = try required([profile]); preconditionFailure("Invalid metadata accepted") } catch OperationError.invalidParameters { }
}
ALTApplication.current = ALTApplication("Spotify", id, ["SideKickBackupAppGroup": group])
let unrelated = try required([profile])
precondition(unrelated.isEmpty)
'''.replace('BODY', body)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'RestoreHelper.swift'
            path.write_text(source, encoding='utf-8')
            binary = Path(directory) / 'fixture'
            subprocess.run([compiler, str(path), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)
