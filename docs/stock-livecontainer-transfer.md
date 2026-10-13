# Stock LiveContainer file-transfer implementation

This implementation changes SideKick and its bundled SideBackup helper. It does not change LiveContainer.

## Entry point

My Apps → installed app → Move to LiveContainer.

1. Create the dedicated guest IPA and save/open it in LiveContainer. It keeps the native resigned bundle ID so preference files use the same domain.
2. Export Native App Files. A same-identity backup helper temporarily replaces the native binary. Choose a local Files destination outside that app's sandbox. It creates a new SideKickData-UUID folder and then the pipeline reinstalls the original binary.
3. Select that folder in SideKick. In stock LiveContainer, import the prepared IPA and attach the same folder through its external data-storage settings. Select that container and verify your saves/settings.
4. Confirm that the guest works, then Move to LiveContainer. The helper takes another snapshot into a separate chosen Files destination before the native app is uninstalled. The app record/source stay available in SideKick.
5. To return, stop every instance of the guest and return to LiveContainer's app list so preferences are flushed. Keep the guest at the original version/build. Choose Restore Latest Guest Files and select its current SideKickData folder in the helper. The native binary is reinstalled after file restoration.
6. Verify the native app before deleting guest files or recovery folders.

Recover Original App Binary handles failures/cancellations that left the helper installed. It reinstalls the source without importing guest files. That is intentionally distinct from restoring guest data.

## Data boundaries

Documents and Library only. Hidden files are copied, source/copy bytes are compared, and missing guest files remain absent after restoration. Both trees stage before replacement; original native trees are retained in a recovery generation under the native home. Keychain items are not exported/imported. Apps with source App Group entitlements are blocked by preflight. Native extensions and entitlement-dependent functionality are not made equivalent by this transfer.

This is for compatible SideKick-managed apps with retained unencrypted source and the same account/team/installation identity. SideKick and LiveContainer themselves are excluded. Do not update the guest before restoration: the folder marker cannot independently detect a binary update made in another app. Restore requires matching source metadata; arbitrary schema upgrades are not supported.

The user-selected Files folder is mutable LiveContainer data. Keep a separate export snapshot before allowing the guest to write. The offload action creates an additional snapshot before slot release. Losing/deleting an app hosting an external folder can remove that folder; store independent recovery copies appropriately.

## Code and reproducibility

- SideKick/Services/AppDataTransfer.swift: shared filesystem engine and identity marker.
- SideKick/Services/NativeAppTransferService.swift: persistent transfer states/bookmark, backup/deactivation/restoration/recovery orchestration.
- SideKick/Views/Library/NativeAppTransferView.swift: guided manual flow.
- scripts/embed-file-transfer.py and scripts/templates/SideKickFileTransferHelper.swift: explicit transfer support added after vendor audit patches in CI. Normal backup behavior is retained when the transfer flag is absent.
- SideStoreOperationService excludes offloaded/interrupted transfers from scheduled native refresh and blocks conflicting native operations.
- Transfer states survive interruption; source, external data, and recovery generations are not deleted automatically.

The native helper does not need a synthetic shared App Group for this path. Its picker obtains access itself; a SideKick bookmark is never assumed usable by another app. Its staged version/build preserve the native app's catalogue metadata. Cleanup skips private backup deletion only during the explicit transfer request.

## Verification

Ubuntu WSL Swift 6.4: 43 portable tests passed, including three new real-filesystem transfer tests. They exercise hidden files, changed preferences, guest deletions, wrong identity/build, links, and a destination nested inside the native home.

The release/integration fixture applies the production patch order to pinned vendor snapshots, adds transfer support, and checks emitted helper metadata. When Swift is available it also syntax-parses the assembled helper file. Release-manifest and existing vendor regression tests pass. UI/source parsing is not an iOS typecheck.

Physical iPhone acceptance remains necessary for same-identity helper installation, actual picker grants, LiveContainer external-folder use/preferences flushing, free-account signing, slot release, interruption recovery and final app behavior. Use a disposable app for the first round-trip. Compilation and portable tests alone do not prove data preservation on an iPhone.
