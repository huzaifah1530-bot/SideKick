# Reversible native-app offload to LiveContainer: research and proposed plan

Date: 13 October 2026. Status: source-based feasibility proposal; no implementation or device acceptance claimed.

## Outcome and verdict

The requested behavior is to free a native sideloaded app slot while keeping the app usable in LiveContainer, then return it to native installation with changes made while running as a guest.

**Feasible for compatible sideloaded apps and transferable filesystem data. A guarantee of all data, credentials, and native functionality for every app is not feasible.** Filesystem compatibility, Keychain access, entitlement availability, and application behavior are separate questions. A successful file copy does not establish successful migration.

This proposal assumes a non-jailbroken device, an app managed by SideKick, an available unencrypted IPA/source bundle, and restoration with the same signing team and resigned installation identity. Arbitrary App Store apps and different-team restoration are outside the initial scope.

## Source inspected

The original LiveContainer/LiveContainer repository returned “Repository not found” during a fresh git request. The available LiveContainerMirror/LiveContainer source was cloned read-only for research and pinned to **4dbe0f9a626de801184a42c0be8d2cb105058e3d**. It identifies itself on GitHub as a fork; these findings apply to that snapshot, not an assurance of provenance, installed-version compatibility, or future API stability.

Local research checkout: C:/Users/Huzaifah/.codex/tmp/livecontainer-offload-research-20261013.

The relevant source paths below were inspected alongside the project's pinned SideStore 0dd743f75afc358b0ba4a002feb5f19474492371 and its local integration/audit patches. Existing vendor working changes were not changed.

| Finding | Source evidence |
| --- | --- |
| Guest binaries and guest data are separate. Documents/Applications stores bundles; Documents/Data/Application/<folder> stores guest homes. | [Shared.swift](https://github.com/LiveContainerMirror/LiveContainer/blob/4dbe0f9a626de801184a42c0be8d2cb105058e3d/LiveContainerSwiftUI/Utilities/Shared.swift#L13) |
| LiveContainer can attach a user-selected external folder using a bookmark, allocate a Keychain group, and register it as a container. | [LCAppSettingsView.swift, importDataStorage](https://github.com/LiveContainerMirror/LiveContainer/blob/4dbe0f9a626de801184a42c0be8d2cb105058e3d/LiveContainerSwiftUI/Views/AppList/AppSettings/LCAppSettingsView.swift#L529) |
| Guest startup resolves that bookmark, obtains security-scoped access, and redirects HOME to the selected folder. | [LCBootstrap.m](https://github.com/LiveContainerMirror/LiveContainer/blob/4dbe0f9a626de801184a42c0be8d2cb105058e3d/LiveContainer/LCBootstrap.m#L392) |
| Containers have LCContainerInfo.plist; guest metadata separately records LCContainers and LCDataUUID. A data directory alone does not register a guest. | [LCContainer.swift](https://github.com/LiveContainerMirror/LiveContainer/blob/4dbe0f9a626de801184a42c0be8d2cb105058e3d/LiveContainerSwiftUI/Models/LCContainer.swift#L134), [LCAppInfo.m](https://github.com/LiveContainerMirror/LiveContainer/blob/4dbe0f9a626de801184a42c0be8d2cb105058e3d/LiveContainerSwiftUI/Models/LCAppInfo.m#L673) |
| Guest preferences use the guest bundle identity and redirected home; saved preferences can be dumped back to Library/Preferences. | [NSUserDefaults.m](https://github.com/LiveContainerMirror/LiveContainer/blob/4dbe0f9a626de801184a42c0be8d2cb105058e3d/LiveContainer/Tweaks/NSUserDefaults.m), [LCSharedUtils.m](https://github.com/LiveContainerMirror/LiveContainer/blob/4dbe0f9a626de801184a42c0be8d2cb105058e3d/LiveContainer/LCSharedUtils.m#L369) |
| App Group access is redirected to simulated folders, optionally HOME/LCAppGroup/<group>. | [NSFileManager+GuestHooks.m](https://github.com/LiveContainerMirror/LiveContainer/blob/4dbe0f9a626de801184a42c0be8d2cb105058e3d/LiveContainer/Tweaks/NSFileManager%2BGuestHooks.m#L36) |
| Keychain calls are rewritten to LiveContainer-specific access groups. Copying Library does not copy Keychain items. | [SecItem.m](https://github.com/LiveContainerMirror/LiveContainer/blob/4dbe0f9a626de801184a42c0be8d2cb105058e3d/LiveContainer/Tweaks/SecItem.m#L118) |
| Guest installation patches/signs the executable. Its presence in the list is not proof of successful signing or launch; the importer retains failed-signing imports. | [LCAppListView.swift](https://github.com/LiveContainerMirror/LiveContainer/blob/4dbe0f9a626de801184a42c0be8d2cb105058e3d/LiveContainerSwiftUI/Views/AppList/LCAppListView.swift#L689) |
| The inspected URL handlers offer install-from-URL and guest launch with a container folder; they do not establish a transactional data-import/export protocol with completion receipts. | [LCAppListView.swift, onOpenURL handling](https://github.com/LiveContainerMirror/LiveContainer/blob/4dbe0f9a626de801184a42c0be8d2cb105058e3d/LiveContainerSwiftUI/Views/AppList/LCAppListView.swift#L1211) |

Platform constraints: [Apple directory access](https://developer.apple.com/documentation/uikit/providing-access-to-directories) grants access to a selected exposed directory, not arbitrary private app sandboxes. [Apple Keychain access groups](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps) depend on signing entitlements. [Secure Enclave keys](https://developer.apple.com/documentation/security/protecting-keys-with-the-secure-enclave) have no plain-text key export/import mechanism.

## What SideStore actually does

There are two distinct paths in this project's vendor source:

- Legacy deactivation removes provisioning profiles and marks the app inactive. It does not copy the app's sandbox into LiveContainer.
- Modern deactivation installs a SideBackup helper over the same resigned app identity, runs the helper inside that identity's sandbox, copies data, then uninstalls and marks the app inactive. Activation installs the helper, restores data, and installs the original binary.

Evidence: OperationStepDefinition.swift:98–159, StandaloneOperations/DeactivateAppOperation.swift:64, PipelineOperations/StageBackupAppOperation.swift:43, and SideBackup/BackupEngine.swift:255 in Vendor/SideStore.

The existing helper captures Documents, Library, and accessible non-store App Groups. It uses skipsHiddenFiles and has no Keychain export in the inspected engine. Restoration copies directory contents into the destination; it does not guarantee removal of files absent from the snapshot. Therefore it is a useful foundation, not an “all data” migration engine.

**SideKick-specific blocker:** patches/sidestore-sidekick.patch redirects the store's shared directory to private Library/Application Support/SideKick and removes mandatory App Group requirements. SideBackup still expects a real shared App Group and writes Backups there. The store and helper must agree on a supported transfer location; private database storage does not magically become shared. SideKick/Services/SideStoreOperationService.swift currently has no offload/restore facade. Fixing this integration is prerequisite work.

## Preservation boundaries

| Data or feature | Proposed treatment |
| --- | --- |
| Documents, settings, databases, Application Support | Transfer with complete manifests and device checks. Preserve hidden user files, database WAL/SHM, and necessary file metadata. |
| Native/resigned preference domain | Track exact identity. Prefer importing a copy whose bundle ID matches the native resigned identity, or explicitly map domains both ways. Never use a display name as identity. |
| App Group files | Capture only groups the helper can legally access. Map exact provisioned group names to the guest's simulated groups; prefer isolated LCAppGroup directories. Shared groups used by another native app require separate handling. |
| Keychain passwords/tokens/exportable keys | Separate optional migration project. A helper needs permitted access groups; LiveContainer needs an explicit import/export operation into its assigned guest group. Exported values require protected transport and correct attribute handling. |
| Secure Enclave keys, inaccessible credentials, persistent Keychain references | Cannot promise portable preservation. Keep native protected state where possible; block unsupported full-data migration or require app-specific recovery. A surviving native Keychain item is not automatically usable by the guest. |
| Cookies/WebKit data, absolute paths, bookmarks, identity-dependent encryption | File copies may succeed while the application fails. Require compatibility testing; arbitrary path rewriting is unsafe. |
| Cloud state, server sessions, push tokens | May need reauthentication or reregistration. Local files cannot ensure server-side continuity. |
| Extensions, widgets, VPN providers, background behavior | Guest entitlements are not inherited by the host; native extension registration is unsupported by LiveContainer's documented guest model. Exclude incompatible apps rather than suggesting equivalence. |

## Approaches considered

1. **Stock LiveContainer with a SideKick-managed external folder — recommended prototype.** The user imports the IPA in LiveContainer and selects the exported data root using LiveContainer's existing external-container picker. LiveContainer owns its bookmark, metadata, signing, and Keychain group. SideKick owns the transferable files and snapshots. This avoids inventing cross-app access or modifying another app's metadata directly. It involves user steps and does not by itself solve Keychain migration.

2. **A cooperating LiveContainer integration — target for a polished feature.** Add or upstream a versioned transfer protocol for import, guest registration, stop/flush/snapshot, and return receipts. It can reduce manual steps and support transferable Keychain items. This requires a compatible LiveContainer build; SideKick alone cannot add endpoints to stock LiveContainer.

3. **Direct writes to selected LiveContainer folders.** Potentially possible where writable access is granted, but fragile: metadata schema, signing completion, preferences, guest processes, and shared groups all need coordination. Do not use this as the default; the existing SideKick integration is intentionally read-only and its Applications bookmark does not grant Data access.

## Proposed user flow

Use “Move to LiveContainer” and “Restore as Installed App.” Explain compatibility and preserved data on the operation review screen, not as permanent home-page warnings.

### Move

1. Check source bundle, signing identity, local device connection, source/helper reinstall capability, storage, guest compatibility, and transferable-data policy. Reject SideKick, LiveContainer itself, encrypted/missing sources, and incompatible apps initially.
2. Retain an immutable, unpatched source bundle. LiveContainer modifies its guest copy; never reinstall that patched executable as the native app.
3. Run a verified helper under the original installation identity and take a complete snapshot. Installing the helper replaces the runnable native binary even before uninstall, so a failed backup must offer immediate reinstallation of the original binary.
4. Stage a dedicated Documents/OffloadedApps/<transaction UUID>/LiveData home. Keep the rollback snapshot elsewhere, protected from guest writes. Export Documents/Library and mapped isolated group files into LiveData.
5. Import the IPA and attach LiveData through LiveContainer. Validate exact guest and container IDs; a successful URL open or listed guest is insufficient. Launch the guest, verify important data, and obtain user confirmation in the initial manual prototype.
6. Reinstall the native binary after helper work if needed. Only release the native slot after backup, source, guest signing, and user data checks succeed. Prefer keeping the inactive native installation when the supported profile-deactivation path releases the required slot; otherwise use verified backup followed by uninstall. Determine slot behavior on the target iOS version before selecting a path.
7. Record the committed offload state with original/resigned IDs, team, native version/build, guest version/build, source hash, LiveContainer instance, guest folder, selected container, snapshot generation, and transfer exclusions. Update associations under the logical offload record without losing existing GitHub baselines.

### Restore

1. Acquire a native app slot and the original identity/team. Check that the retained source matches the guest's data schema. If the guest updated, use a compatible matching native source; do not silently downgrade newer data.
2. Stop the guest and all processes using that container, flush preferences, then snapshot current LiveData. With stock LiveContainer, use an explicit exit/return step and device verification; robust automated quiescence needs the cooperating protocol.
3. Install the restore helper with the original resigned identity and allowed groups. Restore a staged exact filesystem generation, honoring deleted files; keep a rollback generation. Strip only known LiveContainer control files/runtime symlinks, not arbitrary dotfiles.
4. Install the original unpatched binary, validate data in the native app, and mark native restoration complete.
5. Retain guest data until restoration is confirmed. Cleanup is a separate reversible decision where possible. Do not allow both copies to mutate the same logical data generation during transfer.

## Transaction and recovery design

Persist a journal before each external operation: prepared → nativeSnapshotVerified → guestPrepared → guestVerified → nativeSlotReleased → offloaded; returning → guestSnapshotVerified → nativeDataRestored → nativeVerified → restored.

Each step is idempotent and records identities/hashes rather than relying on transient callbacks. Crashes, cancellations, locked-device errors, low storage, revoked bookmarks, failed signing, and expired profiles must leave a recoverable source and snapshot. A missing LiveContainer app must expose Restore and Reconnect, not erase offload records.

Use file coordination and balanced security-scoped access. Reject traversal and escaping links; specially classify runtime symlinks generated by LiveContainer. Keep a manifest of files, hashes, sizes, metadata, excluded paths, and any incomplete copy. Never commit slot release after a partial copy. Backups and live guest data must not share the same mutable generation.

The live folder must be exposed for the picker if using approach 1. Do not assume Library/Application Support is selectable. Document that deleting SideKick would delete a folder hosted in its Documents; provide an independent backup/export and recovery instructions.

## Phased plan and acceptance gates

- [ ] **Phase 1 — prove access and identity:** use a disposable native app containing Documents, a dotfile, UserDefaults, SQLite plus WAL, and a readable Keychain token. Prove same-identity helper replacement preserves files; prove usable transfer transport without the currently assumed store App Group. Failure blocks further work.
- [ ] **Phase 2 — prove a stock-LiveContainer round-trip:** import a clean source copy, attach a dedicated external folder, verify starting data, change a setting and database row, delete a file, exit/flush, restore through the helper, and verify all changes natively. Record Keychain behavior separately. Keep the native installation until this passes.
- [ ] **Phase 3 — establish compatibility policy:** test different resigned IDs, App Group remapping/isolation, credentials, WebKit, updates/data schema upgrades, and actual app-slot release on supported iOS versions. Unsupported data must block the all-data path, not be silently omitted.
- [ ] **Phase 4 — implement SideKick orchestration:** proposed new OffloadRecord model, OffloadJournalStore, AppDataTransferService, and OffloadOperationService; adapt SideStoreOperationService, LiveContainerStore, app management UI, storage ownership, and GitHub target associations. Vendor/helper changes belong in reproducible patches. Review a concrete design before product coding.
- [ ] **Phase 5 — cooperating LiveContainer protocol if needed:** proposed versioned prepareImport/commitImport/quiesce/export operations with transaction receipts, generation checks, user approval in the receiving app, and authenticated local data handoff. URLs carry request IDs, never credential blobs. These are new interfaces, not existing upstream APIs.
- [ ] **Phase 6 — failure recovery:** interrupt at every journal boundary; test insufficient storage, expired profiles, failed helper launch, stale/revoked bookmarks, missing source, running guest, folder deletion, guest update, and failed native verification. Ensure no phase deletes the only usable copy.

Pure Swift tests can prove manifests, identity mapping, state transitions, and path boundaries. Xcode builds verify integrated compilation. Physical iPhone tests are mandatory for helper sandbox identity, signing capabilities, picker access, Keychain migration, LiveContainer preference flushing, slot release, and final app functionality.

## Recommendation

Proceed with the disposable-app external-container round-trip first. It should establish whether this is useful for the user's actual apps before committing to a LiveContainer fork or replacing deactivation. Market the verified result as reversible movement of supported apps and transferable data; do not promise preservation of every login, protected key, or native feature.
