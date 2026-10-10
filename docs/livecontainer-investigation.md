# LiveContainer integration: investigation and proposed design

Date: 10 October 2026. Status: investigation complete enough for design review; integration and screenshot fixes are not implemented or device-verified.

## Requested outcome

SideKick should discover real LiveContainer guests through granted filesystem access, retain their metadata and GitHub sources, show them separately in My Apps, request guest launches, and include them in existing update checks and notifications. The first phase excludes automatic guest IPA installation and any modification of LiveContainer. The supplied shortcut setup link is updated separately.

The screenshots add four requirements: reclaim temporary/signing storage deliberately, make Update a leading icon-and-label action with Options, expose all saved signing accounts with honest capabilities, and allow users to override a suggested installed GitHub build.

The user delegated the account-change policy. Recommended behavior is same-team refresh/re-sign plus an explicit separate installation under another team when a usable source is available. Do not promise data or credential migration between teams; do not delete the original installation automatically. SideKick's own account change must explain that another team cannot inherit its protected credentials or container.

## Verified source and platform facts

The repository supplied in the brief, `hugeBlack/LiveContainer`, is accessible. Source inspected at commit `882ece9ab4bae9e5dfe38f348d1572b8d0ddda55`. Its current repository description says it is deprecated. The linked `LiveContainer/LiveContainer` repository returned 404 through both the GitHub connector and web reader in this session. Compatibility findings below apply to the inspected revision; they do not establish compatibility with an inaccessible successor or arbitrary forks.

| Fact | Evidence |
| --- | --- |
| Private guest bundles are under Documents/Applications. | [Shared.swift, LCPath](https://github.com/hugeBlack/LiveContainer/blob/882ece9ab4bae9e5dfe38f348d1572b8d0ddda55/LiveContainerSwiftUI/Shared.swift#L13) |
| Shared bundles use an App Group's LiveContainer/Applications, with a Documents fallback. | Same LCPath definition. |
| Documents sharing is enabled in this revision. Actual availability in the picker still needs an iPhone test. | [Resources/Info.plist](https://github.com/hugeBlack/LiveContainer/blob/882ece9ab4bae9e5dfe38f348d1572b8d0ddda55/Resources/Info.plist#L171) |
| The guest launch URL is `livecontainer://livecontainer-launch?bundle-name=<app-folder-name>`. An optional parameter is `container-folder-name`. | [AppDelegate.swift](https://github.com/hugeBlack/LiveContainer/blob/882ece9ab4bae9e5dfe38f348d1572b8d0ddda55/LiveContainerSwiftUI/AppDelegate.swift#L96), [LCAppListView.swift](https://github.com/hugeBlack/LiveContainer/blob/882ece9ab4bae9e5dfe38f348d1572b8d0ddda55/LiveContainerSwiftUI/LCAppListView.swift#L679) |
| Launch matching uses the relative bundle folder, rather than CFBundleIdentifier. Locked/hidden apps can require authentication or reject a request. | Same launch handler. |
| A second installation uses `livecontainer2`; upstream also permits changing a copied installation's scheme. | [LCUtils.m](https://github.com/hugeBlack/LiveContainer/blob/882ece9ab4bae9e5dfe38f348d1572b8d0ddda55/LiveContainerSwiftUI/LCUtils.m#L399) and Shared.swift. |
| Guest metadata comes from Info.plist, with supplemental LCAppInfo.plist. Guest bundle IDs can be replaced by LiveContainer's own ID. | [LCAppInfo.m](https://github.com/hugeBlack/LiveContainer/blob/882ece9ab4bae9e5dfe38f348d1572b8d0ddda55/LiveContainerSwiftUI/LCAppInfo.m#L122) |

Read both plists directly. Do not instantiate upstream LCAppInfo: its initializer can repair and write guest files. Respect the upstream spelling `LCOrignalBundleIdentifier` when recovering an original ID; handle the temporary signing key `LCBundleIdentifier` read-only and report an interrupted/partial signing state rather than repairing it.

[Apple's directory-access documentation](https://developer.apple.com/documentation/uikit/providing-access-to-directories) confirms folder selection using UIDocumentPickerViewController, persistent minimal bookmarks, security-scoped access, and coordinated reads. Context7 was also used to check Foundation bookmark and resource-access APIs. A bookmark grants access to the selected exposed location; it grants no blanket access to another app's sandbox or private App Group.

The Files flow can therefore support exposed private Applications folders. Shared storage is supported only when the user can actually grant access to that directory through a file provider. Do not add another app's App Group entitlement or scan fabricated absolute paths. A copied/exported folder is a snapshot, not proof of a live installation: label it accordingly and never infer that its version remains installed.

## Existing SideKick components to reuse

- `AppEnvironment` owns shared observable services and database startup.
- `HomeView` owns My Apps, the update section, foreground reload, and manual GitHub scanning.
- `GitHubUpdateService` implements release/artifact history and exact build keys; `GitHubCredentialStore` supplies named tokens and default selection.
- `GitHubUpdateConfigurationStore` stores JSON associations. It currently keys solely by bundle identifier.
- `GitHubUpdateSettingsView` and its baseline picker provide source configuration and installed-history selection.
- `GitHubUpdateScanner.scanAndNotify()` is called by shortcut/background refresh; `DailyRefreshShortcut` already checks GitHub before local signing operations.
- `GitHubUpdateNotificationScheduler` deduplicates exact build notifications. Its current wording assumes installation through SideKick.
- `IPAImportStore` already uses document bookmarks, owns imported IPA files, and prunes specific abandoned staging patterns.
- `SideKickStorageUsage` measures directories off the main thread. `StorageDirectoryDetailView` is currently read-only.
- `SideStoreOperationService` controls normal signing/install/refresh and calls upstream payload pruning.
- `patches/sidestore-sidekick.patch` adds SideKick as an Xcode synchronized source group. Changes to runtime URL query declarations must update the integrated host plist through this patch as well as `SideKick/Info.plist`.

Preserve pre-existing changes in `Vendor/SideStore` and untracked `dist/`. Do not modify the vendor checkout as part of this work; integration changes belong in SideKick code or root-level build patches. The vendor's participation instructions apply within its tree.

## Screenshot findings

### Retained payloads and temporary files

`SideStoreOperationService.pruneUnusedCaches()` retains each non-deleted installed record's `appBundleFingerprint`. Upstream `CacheAppOperation` deletes only unreferenced payloads. `InstalledApp.fileURL` uses the retained payload as its refresh source, falling back to its instance's App.app. Therefore the payloads in the screenshot cannot all be assumed disposable.

The storage button clears URLCache, recognized abandoned temporary imports, orphaned managed IPAs, and unused signing caches. It does not empty all temporary storage. Existing pipeline patches clean success, failure, and cancellation, but legacy/random files and retained sources remain. The folder browser supplies neither deletion controls nor ownership explanations. These are confirmed code limitations; the exact ownership of the screenshot's three fingerprints requires the device database.

Proposed change: provide classified entries with size, owning app when known, retention reason, and appropriate deletion action. Clean Unused Files should report removed bytes/items, protected items, and failures. Recognized inactive temporary files and unreferenced sources are removable. Explicit removal of a retained source must explain that refresh may require reimporting an IPA. Protect active operations, records, credentials, pairing/configuration files, and external files. Revalidate canonical containment and ownership immediately before removal; reject symlinks and traversal. Never offer generic recursive deletion of arbitrary Library/App Group folders.

### Update layout and missing Options

`AppManagementView.queuedUpdateActions` uses centered Text("Update") without an icon. Its Options link is conditional on more than one same-team account. `GitHubUpdateDetailView` has the same Options visibility restriction.

Proposed change: use leading Label("Update", systemImage: "arrow.down.app") consistently, and always provide Update Options. The options page includes account selection and source/baseline settings where relevant. Missing source/account states remain visible with useful recovery actions.

### Account selection

Refresh, re-sign, and queued update account lists explicitly filter by the current team, and refresh/re-sign services reject another team. Removing only the UI filter would produce errors rather than support other accounts.

Proposed change: show all accounts and the operation each supports. Same-team accounts use the existing operation. Other-team accounts offer a distinct source-based installation, with an explanation that it creates another installation identity and cannot guarantee data transfer. Never call refresh with a different team. If no recoverable source exists, offer IPA import. Keep the original app and records until a separately authorized removal. Verify self-install handling and update association ownership before enabling the SideKick account-change path.

### Suggested baseline overriding a choice

There is a confirmed persistence inconsistency: settings display and update checks prefer `lastInstalledUpdateKey ?? baselineUpdateKey`, but save's `sameBaseline` test prefers `baselineUpdateKey ?? lastInstalledUpdateKey`. Example: original baseline Build 52, last installed Build 81, user chooses Build 52 again. Save regards Build 52 as unchanged and retains last-installed Build 81; future scans continue using Build 81.

Additional risks: loading settings can overwrite an in-memory choice if the parent task reappears; loading a limited history drops a persisted baseline absent from the returned page and replaces it with a recommendation. The tap handler itself sets the binding and dismisses. The exact reported tap failure remains unverified on-device.

Proposed change: one definition of effective baseline; a manual choice wins over recommendations and prior installation markers. Load settings once per target/source context, preserve edits across navigation, reset recommendation state for a new query, invalidate history when source fields change, and discard late results for an old query. Keep an exact historical baseline even when its artifact expired or moved outside the current history page; provide older-history loading. Avoid substring matching as proof of build identity. Regression-test the Build 52/81 case.

## Recommended integration design

### Alternatives considered

1. **Granted directory access with separate guest records (recommended).** Reuses native Files and existing GitHub services, while limiting discovery to storage actually exposed on the device.
2. **Automatic App Group access.** Requires matching entitlements and provisioning that SideKick cannot assume; reject as a baseline solution.
3. **Manual guest metadata or an exported manifest.** Could be a later fallback, but is not live discovery and cannot truthfully satisfy installed-version scanning. No verified upstream inventory export protocol was found in the inspected files.

### Connection and scanner

Add a small actor-backed LiveContainer store under Application Support with versioned, atomically written JSON. Persist connection UUID, display name, bookmark, storage kind, launch scheme, last successful scan, connection status, and guest records. An actor instance is shared through AppEnvironment; background callers must use the same serialized persistence boundary rather than concurrent read-modify-write stores.

Present a `.folder` document picker without copying. Validate a directory named Applications and its readable child bundles. Empty Applications folders are allowed with an honest empty result; arbitrary folders containing no relevant structure are rejected. Validation proves directory structure and readable metadata, not authenticity or freshness of the installation. Tell users to choose the actual LiveContainer folder, and identify snapshots explicitly.

Create `.minimalBookmark` while access is granted; resolve on restart, renew stale bookmarks when access succeeds, otherwise show Reconnect. Use balanced scoped access and NSFileCoordinator for reads. Run enumeration/parsing/icon reads off the main actor, with cancellation and bounded input sizes. Do not follow symlinks outside the selected root.

Parse direct .app children; read display name, original/current bundle ID, short version, build, and accessible icons without modifying the bundle. Missing required bundle identity/metadata creates a scan warning, not a fabricated app. A missing short version can display build or Unknown explicitly. Identity is connection UUID plus relative app-folder name, so duplicate bundle IDs in distinct guest folders remain distinct. A rescan updates matching records and retains associations. Treat a folder rename as a new location unless continuity is proven; do not merge by display name or bundle ID alone.

Commit successful scan results atomically. A root access failure retains previous guests and last successful timestamp. Partial bundle errors retain the affected record with a warning. A confirmed missing folder during a successful complete enumeration marks the guest unavailable instead of silently deleting it. Check cancellation and connection revision before saving a result from a replaced/disconnected connection.

Rescan, Reconnect, Change Folder, and Disconnect are explicit actions. Disconnect removes the bookmark and disables scanning, launch, and automatic update checks while retaining cached metadata and source associations. Offer a separate Forget Connection action to erase SideKick's records/configurations only. Neither action touches guest files.

### Library, launching, and updates

Add a dedicated LiveContainer section and details/connection pages using the existing inset-grouped lists, icons, loading indicators, empty states, and errors. Display version/build, storage/access state, last successful scan, GitHub status, and launch action.

Construct URLs using URLComponents and URLQueryItem with the relative app-folder name. Offer verified primary/secondary schemes and a validated custom scheme for installations where the user knows it. Add primary/secondary query declarations to both build paths. Check availability and recheck guest presence where access permits. UIApplication.open success means a request was accepted, not that a guest launched. If unavailable, show a truthful fallback to opening the appropriate LiveContainer UI; do not present the fallback as guest launch success.

Introduce a minimal GitHub update-target descriptor independent of InstalledAppSummary. Normal apps adapt to it without changing their identifiers. Guest keys use a distinct namespace with connection and location identity. Migrate JSON additively, retaining existing normal-app associations and token selections; serialize all configuration writes through a shared store.

Reuse GitHubUpdateService history and comparison for both target types, plus existing credential selection and deduplication. Show guest status in its section/details; guest candidates must never enter the normal IPA queue, signing, refresh, or install views. Include connected eligible guests in foreground/manual checks and scanAndNotify, hence existing shortcut/background callbacks. Folder access failure must be distinguished from GitHub request failure.

Users choose the exact installed release/run baseline. Discovery does not infer a GitHub build from a name, IPA filename, or unchanged version. A changed version/build can flag the baseline for review, but cannot automatically mark a specific GitHub build installed. Download or launch never advances the baseline. Provide explicit user-confirmed Mark Already Installed and Skip Build controls. Notification wording should invite reviewing a guest update and identify LiveContainer; it must not say it is ready to install through SideKick.

### Shortcut

Only one old SideKick shortcut URL was found in the non-vendor tracked sources: RequiredSetupView's Get Shortcut link. It is replaced with `https://www.icloud.com/shortcuts/2af57f665d434568a589f1e9b7d7f4d1`. The external shortcut's contents are not modified by this repository change. Its existing GitHub scanner callback is the integration point for guest checks.

## Validation required before implementation is called complete

Add a focused Foundation-based test target/package outside the SideKick application source group so tests do not compile into the integrated app. Reuse production scanner/model/store/comparison code, with injectable filesystem, bookmark access, clock, and network behavior. Run it in macOS CI before the integrated iOS build.

Required cases: empty/malformed/binary plists; invalid/missing metadata; duplicate IDs in different folders; inaccessible root and child; bounded icon/plist parsing; symlink/traversal rejection; revoked/stale bookmarks; balanced resource access; scan cancellation; replacing a connection during a scan; repeated scans and restarts; missing/renamed guests; source association retention; guest/normal key separation; exact baseline override and expired historical baselines; unchanged-version new builds; notification deduplication; no guest in signing/IPA queues; and storage ownership/deletion protection during active operations.

For the UI-only changes, use appropriate source/build checks and a navigation smoke test rather than tests that merely mirror label text. Review every changed file and the integration patch, run diff whitespace checks, and verify old URL removal/new URL presence.

This Windows host has Python but no discoverable Swift, Xcode, or gh executable. No Swift tests or iOS builds have run in this session. The existing Actions workflow builds on macOS 15/Xcode 26 but currently contains no SideKick-specific test step. Its build must be run against the changed commit; an old green run is not validation of new work. The GitHub connector rejected the workflow-runs URL attempted in this session, so no CI status claim is made.

Physical iPhone checks remain necessary: private Applications exposure, shared-directory availability, bookmark survival across restarts/revocation, guest launch on primary/secondary installations, locked/hidden guests, background Files access, manual baseline navigation/save, payload removal/reimport recovery, same-team refresh and other-team install behavior. Successful compilation does not establish these behaviors.

## Review checkpoint

Review this proposed architecture and account/storage policies before product implementation. The requested Superpowers brainstorming workflow requires design approval for architectural changes. This document is a concrete proposal for that review; it is not an approved specification or an implementation-completion report.
