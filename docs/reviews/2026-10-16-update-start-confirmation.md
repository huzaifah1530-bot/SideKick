# Visible install/update confirmation — 16 October 2026

## Evidence and investigation

After downloading a GitHub update and tapping Update, the user's screenshot shows Update Status → Preparing your app, 0%, and an empty expanded activity log. `InstallConsoleView.runInstall` writes three activity entries before its first awaited service call, so that screenshot is consistent with the method not having started. It does not establish a ZIP, VPN, authentication or installation-service stall.

The shared console's previous startup gate set `didStart = true`, then waited for a SwiftUI alert whenever install confirmation was enabled (the default). No activity line was written while awaiting that alert. An alert presentation failure could therefore leave this exact screen indefinitely, without a visible way to accept or cancel. Alert failure on the user's device has not been reproduced locally; the confirmed source finding is this invisible pre-install waiting state.

## Change

Replace the startup alert with a visible Ready to Update/Ready to Install page showing app, version, signing account, and explicit Update/Install and Cancel buttons. The confirmation preference is preserved: disabling it still starts automatically. The existing signing/install pipeline is unchanged. Shared usage covers GitHub download updates, queued updates, account-selection installs and imported IPA installs.

`InstallStartState` distinguishes awaiting confirmation, ready, running and finished. Only ready can transition to running, protecting against duplicate task/button starts. The view task is keyed to the confirmation boolean, not the entire state: changing ready → running must not cancel the install's own task. Retry explicitly returns to ready and starts again; view reappearance cannot restart a completed operation. Initial activity lines remain before the first awaited service call.

## Verification and remaining limits

Focused integration checks first failed against the old alert-only startup. New checks validate visible confirmation wiring and compile the actual startup state logic on macOS for confirmation-required, automatic, repeated-start, finished and retry behavior. Local Python fixtures and clean diff checks are run before push. Windows has no Swift/Xcode: the compiled Swift fixture, full iOS build, modal/navigation behavior and successful device self-update are not yet verified. The user requested no build monitoring, and no build status/log tools were called. No releases were created or published.

Next device check: the update must show either the explicit confirmation page or immediate starting activity lines when confirmation is disabled. After acceptance, report the first actual pipeline failure/stage if it still fails; do not infer service failures from an empty pre-start log.

Graphify was consulted before source reads and refreshed after edits. Work remains on main, preserving unrelated dirty VPN, vendor, audit and graph setup files. No subagents were used.
