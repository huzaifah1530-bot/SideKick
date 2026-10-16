# Install/refresh VPN precheck — 16 October 2026

## Device evidence

The user confirmed that Apple ID sign-in succeeded with build 121. This is device validation for that sign-in attempt, not proof of installation or refresh. The user then reported LocalDevVPN being connected while install/refresh demanded that it be connected. Their 13:09:43 refresh screenshot shows the exact `LocalVPNError.externalNotConnected` message immediately after preparing the signing refresh, before a device connection was attempted.

## Root cause and decision

Graphify led to `LocalVPNService.connect`, `performAcquire`, the network scanner and `prepareDeviceConnection`. Source verification shows `externalConnected` is only a live interface-address hint: `utun*` plus `10.7.*`. It does not ask whether the paired iPhone is reachable. `connect` rejected a missing hint before invoking the existing device verification, and `performAcquire` checked the same hint again after connection verification had succeeded. This deterministically prevents a usable connection from being tried whenever that hint is false. The screenshot proves this guard fired; it does not establish why this device's interface snapshot failed to match (custom addresses, interface visibility or transition timing remain possible).

The smallest fix removes these two operation-level hint gates. External operations now run the existing `prepareDeviceConnection`, which enables the local connection configuration, requires a pairing file, starts Minimuxer and calls `ensureMinimuxerReady`. Missing pairing, unreachable device, invalid VPN, cancellation and other real backend errors still propagate. An unrelated active VPN is not accepted as proof of device readiness. The interface hint remains available for setup/status UI; that UI was not reported as the failure and was not broadened in this change.

No new connection probe, VPN toggle, server switch, authentication change or vendor rewrite is added. Existing lease ownership and built-in VPN status checks remain. The existing general diagnostics wrapper records failures in the same operation. A native connection failure may now become visible where the earlier generic LocalDevVPN instruction masked it; a successful device refresh is still required to validate the fix.

## Verification and repository state

A regression test first failed on the original precheck. It extracts the shipping external branch and, on macOS, compiles and runs it with an injected verifier: a false interface hint must still invoke successful verification, while a real verification error must escape. A source guard also covers the redundant post-verification rejection. Local Python release tests (7) passed after the change; Swift execution and the full product build are delegated to the existing macOS Actions workflow.

`LocalVPNService.swift` already had unrelated dirty edits affecting status refresh and built-in VPN cleanup. Those edits were preserved in the working tree and excluded from the commit using partial staging. The vendor checkout, audit work and Graphify setup files were also preserved. Graphify is refreshed after edits. Future sessions should distinguish the address hint, actual device verification and UI snapshot when investigating connection state.

[Actions build 122](https://github.com/huzaifah1530-bot/SideKick/actions/runs/38899185283) succeeded for `30ba0195283559d2cc0dd06e51edda7a4c6c788b`: 68 portable Swift tests, 7 release checks (including execution of the new connection fixture), authentication and vendor regression checks, and the full iOS build passed. The [standard IPA artifact](https://github.com/huzaifah1530-bot/SideKick/actions/runs/38899185283/artifacts/12045279729) was downloaded, its ZIP digest verified against GitHub's SHA-256, and the IPA extracted to `C:\Users\Huzaifah\Downloads\SideKick-build-122.ipa`. Device install/refresh success is not yet verified. Install over the existing app and retry with the current pairing and VPN configuration; any remaining failure should be assessed from the actual backend error.
