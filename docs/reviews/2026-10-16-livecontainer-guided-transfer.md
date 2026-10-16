> Historical implementation: retired by the simpler SideStore offload flow. Data/credential migration described below is no longer shipped.

# Guided LiveContainer transfer — 16 October 2026

The user confirmed build 125 resolved the local connection failure. During the next device test, tapping Create LiveContainer IPA for Spotify appeared to do nothing. The user requested a page-by-page flow instead of all transfer and recovery controls on one long form.

## Findings and decisions

The button is wired to `NativeAppTransferService.prepareGuestIPA`. However, its previous UI placed both progress and errors at the bottom of the long form. It also performed synchronous bundle copying and ZIP packaging on the main actor, preventing responsive feedback while those operations ran. The available evidence does not identify Spotify's actual underlying error: App Groups, unavailable source or version identity checks can fail before packaging. Preserve those checks rather than assume or bypass a compatibility failure.

`NativeAppTransferView` now switches between five pages: import app, export data, select the exported folder, attach/test it in LiveContainer, and optionally free the native slot. Recovery/restoration has its own page. Show operation-specific progress in the page header, present failures in an alert, and automatically open the existing native IPA share sheet on successful creation. The user explicitly confirms import and data verification; sharing or opening a file never establishes successful installation or data migration. Navigation forward to removal remains gated by the verified flag and a validated data-folder bookmark, with the existing backup/removal confirmation intact.

Resume derives from the persisted transfer record: exported data resumes at folder selection or verification, confirmed data resumes at the finish page, offloaded apps resume at completion, and interrupted operations route to recovery. A return within the existing screen keeps the current step and created IPA. Closing before data export starts resumes at creation; no unverified guest-import state is persisted. Recovery failures remain visible and do not erase exported files.

Keep database/identity lookup on its owner actor. Capture only the source URL and identity string for a detached packaging task, and construct bundle/ZIP objects inside that task. Use the existing transfer interlock and storage-operation guard for the whole packaging lifetime, forwarding cancellation and preserving temporary-file cleanup. Persist only enum/numeric diagnostics under LiveContainer transfer, with separate IPA-creation and app-file stages; no app files, paths or account data enter diagnostic storage.

## Verification

Focused regression checks first failed against the old single-page view. Coverage checks the feedback/background-packaging boundary and compiles the actual page-resume logic on macOS to exercise first use, export, selected-folder, verified, offloaded and interrupted states. Existing release, vendor composition, core tests and the full iOS build are required before IPA handoff. Windows cannot typecheck SwiftUI/UIKit or execute device transfer behavior. Physical-device validation of Spotify creation/import and subsequent data transfer remains required.

Graphify was consulted for the view, service, archive helper and diagnostics relationships. The integration uses the canonical patched SideStore build; root source edits ship through that integration. Unrelated VPN, vendor, audit and graph setup work is preserved. No subagents were used.
