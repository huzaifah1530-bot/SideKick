"""Add the explicit, on-device credential-copy mode after file-transfer integration."""
from pathlib import Path
import sys

root = Path(sys.argv[1] if len(sys.argv) > 1 else "Vendor/SideStore")
repo = Path(__file__).resolve().parents[1]


def edit(relative, old, new):
    path = root / relative
    text = path.read_text(encoding="utf-8")
    if text.count(old) != 1:
        raise RuntimeError(f"{relative}: expected one credential integration point")
    path.write_text(text.replace(old, new), encoding="utf-8", newline="\n")


edit("SideStore/Core/Operations/PipelineOperations/StageBackupAppOperation.swift",
     '            updates["SideKickFileTransfer"] = true',
     '''            updates["SideKickFileTransfer"] = true
            if let request = UserDefaults.standard.dictionary(forKey: "SideKickCredentialTransferRequest"),
               let groups = request["sourceGroups"] as? [String],
               let group = request["group"] as? String,
               let container = request["container"] as? String,
               let team = request["team"] as? String {
                let metadata: [String: any Sendable] = ["sourceGroups": groups, "group": group, "container": container, "team": team]
                updates["SideKickCredentialTransfer"] = metadata
            }''')

edit("SideBackup/SideBackupApp.swift",
     '    fileprivate func performSideKickFileTransfer(restoring: Bool) async {',
     '''    fileprivate func performSideKickFileTransfer(restoring: Bool) async {
        if !restoring, Bundle.main.object(forInfoDictionaryKey: "SideKickCredentialTransfer") != nil {
            await performSideKickCredentialTransfer()
            return
        }''')

with (root / "SideBackup/SideBackupApp.swift").open("a", encoding="utf-8", newline="\n") as output:
    for relative in ["SideKick/Services/AppCredentialTransfer.swift", "SideKick/Services/SystemAppCredentialStore.swift", "scripts/templates/SideKickCredentialTransferHelper.swift"]:
        output.write("\n" + (repo / relative).read_text(encoding="utf-8"))

edit("SideStore/Core/Operations/PipelineOperations/CacheResignedMetadataOperation.swift",
     '        try cacheProvisioningProfiles(for: installedApp)',
     '''        // Refreshed.ipa is deleted after installation. Retain only the actual
        // signed permissions needed for future on-device login transfers.
        // A temporary helper must never replace the native app's evidence.
        if targetAppBundle.executableName != "SideBackup" {
            let signed = targetAppBundle.entitlements
            let permissions = signed.filter { ["keychain-access-groups", "application-identifier"].contains($0.key) }
            let metadata: [String: any Sendable] = [
                "id": targetAppBundle.bundleIdentifier, "version": targetAppBundle.version,
                "build": targetAppBundle.buildVersion, "entitlements": permissions,
                "info": targetAppBundle.infoPlist.filter { $0.key == "CFBundleURLTypes" }
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: metadata, format: .binary, options: 0)
            try FileManager.default.createDirectory(at: installedApp.directoryURL, withIntermediateDirectories: true)
            try data.write(to: installedApp.directoryURL.appendingPathComponent("CredentialTransferSigning.plist"), options: .atomic)
        }
        try cacheProvisioningProfiles(for: installedApp)''')

# The embedded helper requests no permanent extra Keychain groups. Only this
# explicit invocation gets exact source/destination groups, bounded by the
# provisioning profile. Imported IPA entitlements follow the ordinary signer.
edit("Dependencies/SideSign/Sources/CodeSigning/CodeSignerAPI.swift",
     '            verboseLog("[SideSign] Filtered entitlements for signing: \\(filteredEntitlements)")',
     '''            if app.executableName == "SideBackup",
               app.infoPlist["SideKickFileTransfer"] as? Bool == true,
               let request = app.infoPlist["SideKickCredentialTransfer"] as? [String: any Sendable] {
                guard let source = request["sourceGroups"] as? [String],
                      let destination = request["group"] as? String,
                      let team = request["team"] as? String, team == matchedProfile.teamIdentifier,
                      let permitted = matchedProfile.entitlements["keychain-access-groups"] as? [String],
                      let requested = AppCredentialSigningPolicy.groups(source: source, destination: destination, team: team, permitted: permitted) else {
                    throw SignerError.invalidApp(cause: "Login transfer Keychain permissions are unavailable.")
                }
                filteredEntitlements["keychain-access-groups"] = requested
            }

            verboseLog("[SideSign] Filtered entitlements for signing: \\(filteredEntitlements)")''')

with (root / "Dependencies/SideSign/Sources/CodeSigning/CodeSignerAPI.swift").open("a", encoding="utf-8", newline="\n") as output:
    output.write("\n" + (repo / "SideKick/Services/AppCredentialSigningPolicy.swift").read_text(encoding="utf-8"))

print("Installed on-device login transfer support")
