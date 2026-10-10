# LiveContainer integration and app-management changes

## User flows

- My Apps has a separate LiveContainer section. Link the actual `Applications` directory exposed in Files, then choose the installation's scheme (`livecontainer`, `livecontainer2`, or a known custom scheme).
- Connections support rescan, reconnect, another directory, disconnect, and forget. Disconnect keeps metadata and GitHub sources. Forget removes SideKick's records and sources; neither action changes guest files.
- Guest details show real Info.plist version/build, bundle identity, location, last-seen time, connection issues, GitHub settings, and launch actions. Malformed/inaccessible bundles retain prior metadata with a warning.
- Guest update sources use the existing named GitHub tokens and release/workflow history. Pick an exact installed baseline; matching names or unchanged version labels do not prove which build was installed.
- Foreground, manual, background, and shortcut checks include connected accessible guests. Notifications use the existing exact-build deduplication. Snapshot and disconnected connections are excluded.
- Guest updates are installed through LiveContainer. SideKick only tracks availability and supports user-confirmed Already Installed / Skip actions. It never queues a guest for normal signing or marks a build installed after a launch/download.
- Cached & Temporary Files in Storage explains file ownership and retained signing sources, with explicit removal controls. Clean Unused Files reports removed space, retained sources, and failures. Removing a current source leaves the installed app/records intact but can require importing its original IPA before refresh.
- Update rows have a leading icon and label; Options is offered with one or more saved accounts. Every saved account is visible. Same-team choices use refresh/update/re-sign; another team leads to a separate source-based installation review, with no promise of data/credential transfer and no automatic original removal.
- Installed GitHub baseline selection survives navigation and missing/expired history entries. A manual override supersedes the prior installed-build marker. Reload and older-history loading are available; suggestions never force selection.
- Setup's Get Shortcut now points to `2af57f665d434568a589f1e9b7d7f4d1`. The external iCloud shortcut's contents were not modified.

## Supported limits

The inspected upstream source is `hugeBlack/LiveContainer` revision `882ece9ab4bae9e5dfe38f348d1572b8d0ddda55`. That repository describes itself as deprecated; its linked successor returned 404 during investigation. Arbitrary fork compatibility is not established.

Discovery is read-only and only accesses granted, exposed directories. SideKick cannot unlock another app's sandbox or private App Group. Shared apps are discoverable only when their actual shared Applications directory is exposed through a provider. Exported copies must be identified as snapshots; they do not prove installed versions and cannot launch guests or run automatic update checks.

The directory name and readable metadata validate structure, not authenticity. Select the actual LiveContainer directory. Icons stored only in an Assets.car file may use the fallback icon; the scanner reads accessible icon image files without reverse-engineering asset catalogues. Limits: 5,000 directory entries, 1 MB per plist, 1,024 UTF-8 bytes per metadata string, 4 MB per icon, and 32 MB of icons per scan.

Launch requests use the verified `livecontainer-launch` host and `bundle-name` app-folder parameter with URLComponents encoding. Opening a URL only confirms that iOS accepted the request; it does not prove guest execution. LiveContainer owns authentication, JIT, and launch errors. Custom schemes are opened directly because iOS query declarations cannot enumerate arbitrary user-created installations.

Temporary items less than 24 hours old or owned by the running process are protected to avoid deleting active work. Databases, account credentials, pairing/settings, linked originals, and arbitrary Library/App Group data have no generic delete action. Required signing payloads have an explicit source-removal confirmation. Signing starts and update downloads are blocked during removal, and cleanup refuses active app operations/downloads.

Different-team installation follows the existing signing engine, whose default app identity appends the selected team. If the user customizes identifiers, they must keep a distinct bundle ID to retain the original. SideKick's own separate installation has its own database and credentials. Physical-device validation is required before claiming account migration or data preservation.

Installed copies are keyed by their resigned bundle identifiers for management, update settings, and queued IPAs. Existing original-ID settings and queues migrate only when exactly one copy exists, preserving tokens and build baselines. Ambiguous legacy queues require choosing the installation again. Accounts without saved sessions stay visible and open their reconnect page. Retained-source deletion revalidates the stable set of owning installation IDs, even when their display names match.

Cancellation immediately returns from a stalled provider scan, cancels its coordination request, and rejects late results. The worker keeps its security scope balanced until outstanding reads actually finish. Older history remains reachable even if the first page contains no usable artifacts.

## Validation record

The Foundation production scanner, JSON stores, model identity, exact-build comparison, and path validation are compiled directly into the root Swift package. `swift test` runs in Ubuntu WSL with the official Swift 6.4 toolchain. The initial tests failed for missing production APIs. The reconnect/disconnect race and blocked-provider cancellation regressions were observed failing, then fixed. The final local suite passed 25 tests, including installation-specific queue retention and same-name ownership changes.

The suite covers real binary/xml plist fixtures, empty folders, malformed and oversized metadata, duplicate IDs, symlinks including ancestors/plists, repeated scans, version changes, source association persistence, missing roots/guests, partial scans, disconnect/forget, simulated revoked/stale bookmark signals, encoded launch URLs, exact baseline override, and retained payload policy. Linux tests exercise injected bookmark access and do not validate iOS's security-scope implementation.

The Actions workflow runs the same core tests on macOS before the integrated Xcode 26 device build and validates `codex/**` branches. The integration patch must apply to the pinned vendor index. Swift syntax parsing checks UI files locally but is not a UIKit/SwiftUI typecheck.

Physical iPhone testing remains required for: picker exposure of private/shared storage, persistent security scope across restarts and revocation, file coordination/provider behavior, primary/secondary/custom guest launch, locked/hidden guests, background directory access, notification delivery/deduplication, baseline selection navigation, deleting/reimporting retained sources, actual refresh/signing, and other-team/self installation. No on-device behavior is claimed verified by this work.

## Changed-file map

| Files | Responsibility |
| --- | --- |
| `Models/LiveContainerModels.swift`, `Services/LiveContainerScanner.swift`, `Services/LiveContainerStore.swift` | Guest identities, read-only bounded scanner, serialized catalogue/bookmark persistence |
| `Views/LiveContainer/LiveContainerViews.swift`, `App/AppEnvironment.swift`, `Views/Home/HomeView.swift` | Native library, connection/detail navigation, foreground checks |
| `Models/GitHubUpdateConfiguration.swift`, `Services/GitHubUpdateConfigurationStore.swift`, `Services/GitHubUpdateService.swift`, `Services/GitHubUpdateScanner.swift`, `Services/GitHubUpdateNotificationScheduler.swift` | Shared target descriptors/stores, exact history comparison, guest checks and notification copy |
| `Views/Library/GitHubUpdateSettingsView.swift` | Persistent user baseline edits, recommendations, history reload/pagination |
| `Views/Library/AppManagementView.swift`, `Views/Library/GitHubUpdateDetailView.swift`, `Views/Library/OtherTeamInstallationView.swift` | Update layout/options and all-account capability routing |
| `Services/SideKickStorageCleanup.swift`, `Services/SideKickStorageUsage.swift`, `Views/Settings/StorageFilesView.swift`, `Views/Settings/SideStoreSettingsPages.swift` | Classified storage, path protection, removal/cleanup controls and reporting |
| `Services/SideStoreOperationService.swift`, `Services/GitHubUpdateDownloadStore.swift` | Shared configuration actor, signing/removal interlocks, guest queue exclusion |
| `Info.plist`, `patches/sidestore-sidekick.patch` | LiveContainer query declarations in both build paths |
| `Views/Root/RequiredSetupView.swift` | Updated shortcut setup link |
| Root `Package.swift`, `Tests/SideKickCoreTests/*`, `.github/workflows/ios-build.yml`, `.gitignore` | Automated core tests, macOS CI, ignored test build outputs |
| `README.md`, `docs/settings-functionality.md`, investigation/plan/integration documents | User behavior, constraints, implementation and validation record |

All `Models`, `Services`, `Views`, `App`, and `Info.plist` entries above are under `SideKick/`. Pre-existing `Vendor/SideStore` working changes and `dist/` were not included in the implementation commits.
