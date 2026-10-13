"""Wire a Files-based transfer into SideBackup only for explicit SideKick requests.
Run after all vendor patches. Does not touch LiveContainer.
"""
from pathlib import Path
import sys

root = Path(sys.argv[1] if len(sys.argv) > 1 else "Vendor/SideStore")
repo = Path(__file__).resolve().parents[1]

def edit(relative, old, new):
    path = root / relative
    text = path.read_text(encoding="utf-8")
    if text.count(old) != 1:
        raise RuntimeError(f"{relative}: expected one transfer integration point")
    path.write_text(text.replace(old, new), encoding="utf-8", newline="\n")

edit("SideStore/Core/Operations/PipelineOperations/StageBackupAppOperation.swift",
     '        context.additionalEntitlements[.appGroups] = targetAppGroups',
     '''        if UserDefaults.standard.bool(forKey: "SideKickFileTransferRequest") {
            // Explicit file-only transfer. No synthetic shared App Group needed.
            updates["SideKickFileTransfer"] = true
            updates["SideKickSourceVersion"] = targetApp.version
            updates["SideKickSourceBuild"] = targetApp.buildVersion
            // Installing the helper must not change the retained app's version
            // to SideBackup's own version, especially before deactivation.
            updates["CFBundleShortVersionString"] = targetApp.version
            updates["CFBundleVersion"] = targetApp.buildVersion
            context.additionalEntitlements[.appGroups] = []
        } else {
            context.additionalEntitlements[.appGroups] = targetAppGroups
        }''')
edit("SideBackup/SideBackupApp.swift",
     "        if let error = ConsoleLog.bootCheckError {",
     '        if Bundle.main.object(forInfoDictionaryKey: "SideKickFileTransfer") as? Bool != true, let error = ConsoleLog.bootCheckError {')
for name, restoring in [("backup", "false"), ("restore", "true")]:
    declaration = f"    private func {name}(skipNonCopyable: Bool = false) async {{"
    edit("SideBackup/SideBackupApp.swift", declaration,
         declaration + f'''
        if Bundle.main.object(forInfoDictionaryKey: "SideKickFileTransfer") as? Bool == true {{
            await performSideKickFileTransfer(restoring: {restoring})
            return
        }}''')
path = root / "SideBackup/SideBackupApp.swift"
with path.open("a", encoding="utf-8", newline="\n") as output:
    output.write("\n" + (repo / "SideKick/Services/AppDataTransfer.swift").read_text(encoding="utf-8"))
    output.write("\n" + (repo / "scripts/templates/SideKickFileTransferHelper.swift").read_text(encoding="utf-8"))

# External snapshots are retained until native verification; the regular cleanup
# step must not delete an unrelated private backup with the same bundle identity.
edit("SideStore/Core/Operations/PipelineOperations/RemoveBackupDataOperation.swift",
     "        try await super.executePreconditionCheck(parentProgress: parentProgress)",
     '''        try await super.executePreconditionCheck(parentProgress: parentProgress)
        if UserDefaults.standard.bool(forKey: "SideKickFileTransferRequest") {
            self.setProgress(100)
            return true
        }''')
print("Installed SideKick file-only transfer helper support")
