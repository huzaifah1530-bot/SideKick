"""Keep the native backup engine, with SideKick group routing, UI and progress."""
from pathlib import Path
import sys

root = Path(sys.argv[1] if len(sys.argv) > 1 else "Vendor/SideStore")
repo = Path(__file__).resolve().parents[1]


def edit(relative, old, new):
    path = root / relative
    text = path.read_text(encoding="utf-8")
    if text.count(old) != 1:
        raise RuntimeError(f"{relative}: expected one backup integration point")
    path.write_text(text.replace(old, new), encoding="utf-8", newline="\n")


edit("SideStore/Core/Operations/PipelineOperations/StageBackupAppOperation.swift",
     '''        if !targetAppGroups.contains(Bundle.baseAltStoreAppGroupID) {
            targetAppGroups.append(Bundle.baseAltStoreAppGroupID)
        }''',
     '''        guard let backupGroup = Bundle.main.altstoreAppGroup,
              FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: backupGroup) != nil else {
            throw OperationError.invalidParameters("SideKick's shared backup storage is unavailable. Reinstall SideKick with App Group support before offloading.")
        }
        // The helper adopts the target app's bundle ID, not the store's identity.
        updates["SideKickBackupAppGroup"] = backupGroup
        if !targetAppGroups.contains(backupGroup) { targetAppGroups.append(backupGroup) }''')

edit("Shared/Extensions/Bundle+AltStore.swift",
     '        let appGroup = self.appGroups.first { $0.contains(Bundle.baseAltStoreAppGroupID) }',
     '''        if let expected = self.object(forInfoDictionaryKey: "SideKickBackupAppGroup") as? String {
            // Metadata never grants access: the signed executable must grant it.
            return self.appGroups.contains(expected) ? expected : nil
        }
        let appGroup = self.appGroups.first { $0.contains(Bundle.baseAltStoreAppGroupID) }''')

edit("SideStore/Core/Operations/PipelineOperations/FetchProvisioningProfilesOperation.swift",
     '        // Currently Build.xconfig for debug appends suffix as TEAMID already',
     '''        if targetAppBundle.infoPlist["SideKickBackupAppGroup"] as? String == groupIdentifier {
            guard Bundle.main.appGroups.contains(groupIdentifier),
                  ALTApplication(fileURL: Bundle.Info.activeBundleURL)?.provisioningProfile?.teamIdentifier == team.identifier else {
                throw OperationError.invalidParameters("Offloading requires the app and SideKick to use the same signing team and shared backup group.")
            }
            // This is an existing signed store group. Do not append the team twice.
            return groupIdentifier
        }
        // Currently Build.xconfig for debug appends suffix as TEAMID already''')

edit("SideBackup/ConsoleLog.swift",
     'throw SideBackupError.appGroupNotConfigured(expected: Bundle.baseAltStoreAppGroupID)',
     'throw SideBackupError.appGroupNotConfigured(expected: Bundle.main.object(forInfoDictionaryKey: "SideKickBackupAppGroup") as? String ?? Bundle.baseAltStoreAppGroupID)')
edit("SideBackup/ConsoleLog.swift",
     'SideBackup was likely not resigned with the SideStore App Group entitlement.',
     "SideKick's backup helper is missing its shared backup permission.")

edit("SideStore/Core/Operations/PipelineOperations/ResignAppOperation.swift",
     '        self.debugLog("[ResignAppOperation] Resigned app',
     '''        if resignedAppBundle.isAltStoreApp {
            let groups = resignedAppBundle.entitlements[.appGroups] as? [String] ?? []
            let existingGroup = Bundle.main.altstoreAppGroup
            guard groups.contains(where: { $0.contains(Bundle.baseAltStoreAppGroupID) }),
                  existingGroup.map({ groups.contains($0) }) ?? true else {
                throw OperationError.invalidParameters("SideKick's update is missing its shared backup permission. The installed app has not been replaced. Use a SideKick build that preserves App Groups.")
            }
        }
        if resignedAppBundle.executableName == "SideBackup" {
            guard let expected = resignedAppBundle.infoPlist["SideKickBackupAppGroup"] as? String,
                  (resignedAppBundle.entitlements[.appGroups] as? [String] ?? []).contains(expected) else {
                throw OperationError.invalidParameters("The backup helper was signed without SideKick's shared backup group. The native app has not been replaced.")
            }
        }
        self.debugLog("[ResignAppOperation] Resigned app''')

# Return the existing progress object; callers that ignore it keep working.
for name in ["activate", "deactivate", "restore"]:
    edit("AltStore/Managing Apps/AppManager.swift",
         f'    func {name}(_ installedApp: InstalledApp, presentingViewController: UIViewController?, completionHandler: @escaping (Result<InstalledApp, Error>) -> Void)',
         f'    @discardableResult\n    func {name}(_ installedApp: InstalledApp, presentingViewController: UIViewController?, completionHandler: @escaping (Result<InstalledApp, Error>) -> Void) -> RefreshGroup')
    edit("AltStore/Managing Apps/AppManager.swift",
         f'        self.pipelineRunner.performSingleOperation(.{name}(installedApp),',
         f'        return self.pipelineRunner.performSingleOperation(.{name}(installedApp),')

edit("SideStore/Core/Operations/PipelineExecutor.swift",
     '        for pipelineStep in pipelineSteps {',
     '''        for pipelineStep in pipelineSteps {
            NotificationCenter.default.post(name: Notification.Name("SideKick.pipelineStep"), object: nil,
                userInfo: ["appID": operation.bundleIdentifier, "step": String(describing: pipelineStep.step)])''')

(root / "SideBackup/ContentView.swift").write_text(
    (repo / "scripts/templates/SideKickBackupView.swift").read_text(encoding="utf-8"), encoding="utf-8", newline="\n")
print("Installed SideKick backup group routing, helper interface and pipeline progress")
