# Vendor AltStore audit — 2026-10-12

Scope: `Vendor/SideStore/AltStore` and `Vendor/SideStore/AltStore.xcodeproj`. Audit only; no vendor modifications or external publication. Integrated SideKick builds apply `patches/sidestore-sidekick.patch`, compile the synchronized AltStore group, and replace SceneDelegate's root with SideKick `ContentView`. Consequently upstream controllers are retained dependencies/legacy entry points, not evidence of SideKick's primary Home UI. Reachability is stated per finding. Windows prevents Xcode/device verification; findings below are static evidence, with runtime risks identified separately.

## VA-001 — P2 — Shared operation-progress dictionaries are read without their lock

**Where:** `Vendor/SideStore/AltStore/Managing Apps/AppManager.swift:774–777` (`isActivelyManagingApp(withBundleID:)`).

**Why/evidence:** `set(_:for:)` at 820–841 mutates both Swift dictionaries inside `progressLock.withLock`, and `progress(for:)`, `refreshProgress(for:)`, and `isActivelyManagingAnyApp` use the same lock. This single accessor reads `installationProgress.keys` and `refreshProgress.keys` without it. Actual callers include background reconciliation (94), cache pruning (124), `SideStore/Core/Storage/CacheManager.swift:99`, and `ClearAppCacheOperation.swift:168`, while PipelineRunner registers/clears progress from asynchronous operations. `@unchecked Sendable` supplies no synchronization. Concurrent read/write is a Swift dictionary data race, potentially crashing or incorrectly treating a live install as inactive during cleanup. This code remains reachable through SideKick's shared AppManager engine even though its legacy tabs are replaced.

**Fix suggestion:** Capture both membership checks in `progressLock.withLock`, following adjacent accessors; keep managed-object property reads outside the lock. Validate with concurrent install/cache-cleanup stress and Thread Sanitizer on macOS/iOS.

## VA-002 — P2 — Background source refresh invents an empty build number, causing repeated update notifications

**Where:** `Vendor/SideStore/AltStore/AppDelegate.swift:525`.

**Why/evidence:** The old `_buildVersion` is mapped using `$0.isEmpty ? nil : ""`; every nonempty build value becomes the empty string rather than its original value. Line 528 compares that result to `latestSupportedVersion.buildVersion`. Example: old and new version `1.0`, build `42` produce old `""` versus new `"42"`, so every source fetch announces the same update again. The surrounding comment explicitly requires exact old/new version matching. AppDelegate remains the application entry point and its background-fetch/source-refresh path is unchanged by the integration patch. Actual background scheduling depends on the user's background refresh setting.

**Fix suggestion:** Preserve the nonempty value (`$0.isEmpty ? nil : $0`) and verify that identical version/build suppresses notification while a changed build notifies once.

## VA-003 — P2 (retained upstream UI) — PillButton's display link permanently retains its button

**Where:** `Vendor/SideStore/AltStore/Components/PillButton.swift:161–178`; initialization trigger at `78–86` and `267–270`.

**Why/evidence:** The lazy CADisplayLink targets `self`, is added to the main run loop in `.common`, and its only teardown is in `deinit`. CADisplayLink retains its target, so the button cannot reach deinit while the link remains registered. Assigning `countdownDate = nil` still evaluates `self.displayLink.isPaused`, initializing and registering the link even when no countdown was requested; normal `AppBannerView.configure` calls `resetDisplayState`, which performs exactly that assignment. Pausing the link does not release its target. Reopening retained upstream app/detail or resign UI therefore leaks buttons/links, and active countdowns can keep ticking after dismissal. The SideKick root replaces legacy tab navigation; this is not a claim that its native SwiftUI Home buttons leak. The vendor component stays compiled and used by upstream authentication/resign controllers and banner views.

**Fix suggestion:** Use a weak-target proxy and invalidate the link explicitly when its owner leaves use; avoid constructing it for nil dates. Validate repeated present/dismiss with Memory Graph and confirm links unregister from `.common` rather than the different `.default` mode currently used in deinit.

## VA-004 — P3 (retained upstream UI) — Empty placeholders disable their only retry gesture

**Where:** `Vendor/SideStore/AltStore/Core/DataSources/CellContentDataSource.swift:81–82`, paired with `Browse/BrowseViewController.swift:104–107,345–350`.

**Why/evidence:** When there are zero items, the reusable data source sets the collection view's `isScrollEnabled = false`. Browse's failed first-load state shows “Unable to Fetch Apps” and the underlying error, but has no retry button; its retry action is the UIRefreshControl pull gesture on that now-disabled scroll view. Empty results thus remove the interaction needed to recover from a failed first source fetch without navigating elsewhere/relaunching. The same generic placeholder behavior applies across upstream empty lists. This is retained upstream UI, not SideKick's new Home.

**Fix suggestion:** Leave vertical scrolling/bounce enabled on lists that use pull-to-refresh, or give the placeholder an explicit Retry action. Verify an initial network failure followed by restored connectivity can retry from the same screen.

## VA-005 — P3 — Six duplicated prefetch implementations share a task-replacement bug

**Where:** `Vendor/SideStore/AltStore/Core/DataSources/ArrayDataSource.swift:67–78`; duplicates at `152–153`, `CompositeDataSource.swift:248–257,343–352`, `FetchedResultsDataSource.swift:345–356,420–431`.

**Why/evidence:** Collection/table variants across array/composite/fetched-results classes repeat the same cancellation, cache, async load, identity checking and completion code. Each cancels the old task for an IndexPath, installs a new task under that same key, and lets the old cancelled task's unconditional `defer { removeValue(forKey: indexPath) }` remove the *new* registration when the old task unwinds. Subsequent cancellation/prefetch checks can no longer find the new load, creating duplicate work and losing cancellation control. It is a deterministic logical interleaving, independent of whether actor isolation prevents memory races. The six copies also mean every fix needs synchronized edits. These classes are compiled shared upstream list infrastructure; primary SideKick SwiftUI Home is not implemented with them.

**Fix suggestion:** Centralize task/cache bookkeeping in one reusable loader with a generation/identity token and only clear an entry when the finishing task owns that generation. Keep table/collection adapters thin; verify cancel/reconfigure/replacement using a controlled delayed image loader.

## VA-006 — P1 — Corrupt screenshot data can trap source decoding in an infinite loop

**Where:** `Vendor/SideStore/AltStore/Core/Model/AppScreenshot.swift:188–209`, especially `204–207`.

**Why/evidence:** The `while !container.isAtEnd` loop first decodes an element as URL, then as AppScreenshot. When both fail it logs “Skipping” but neither decodes/consumes an arbitrary element nor increments/advances the unkeyed container. Failed decoding does not consume the entry. A source screenshot entry like `{ "width": 100 }` fails URL decoding and then fails the required `.imageURL` decoding at 87; the loop retries exactly that entry indefinitely. This can monopolize a decoding worker, spam captured logs, and prevent source fetch completion instead of importing the rest. `StoreApp` uses AppScreenshots as its source decoding model, so this is engine data parsing retained in SideKick, independent of the replaced legacy screenshot UI.

**Fix suggestion:** On a failed element, actually consume it using a tolerant discard Decodable/superDecoder, or fail the source with a precise screenshot-index decoding error. Ensure any partially inserted managed screenshot is removed. Validate malformed object, null, number and valid-following-entry inputs terminate and do not leave inserted invalid objects.

## VA-007 — P2 — Reconfiguring a nonexistent placeholder item when updates exist

**Where:** `Vendor/SideStore/AltStore/My Apps/MyAppsViewController.swift:667–670`; placeholder count at `:340`.

**Reachability:** Retained upstream My Apps UI. Integration replaces the root with SideKick's SwiftUI ContentView, so this is not the native SideKick Home screen; the controller and storyboard remain upstream UI code.

**Evidence / why:** The no-updates data source supplies one item only when the updates count is zero (`:340`). `update()` unconditionally asks UICollectionView to reconfigure `(item: 0, section: noUpdates)` whenever checks/refresh-all are idle (`:667–670`), including after `viewIsAppearing` calls `update()` (`:177`). When one or more updates exist, that section has zero items and this index path is invalid. UIKit's item reconfiguration requires an existing item; presenting the list with available updates can produce an invalid-update exception instead of displaying updates.

**Suggested fix:** Reconfigure the placeholder only when its item count is nonzero (or target existing visible placeholder paths). Exercise both zero and nonzero update states and a transition between them. Static analysis only; no device execution.

## VA-008 — P3 — Unsupported-update guidance recommends upgrading even when the OS is already too new

**Where:** `Vendor/SideStore/AltStore/My Apps/MyAppsViewController.swift:1097`, maximum OS branch `:1112–1114`.

**Reachability:** Retained upstream My Apps UI; not SideKick's replacement Home.

**Evidence / why:** Every unsupported-updates alert starts with “Please update your device to the latest iOS version to install them.” But the same alert explicitly includes apps whose `maxOSVersion` is below the current OS and describes those as requiring “iOS … or earlier.” Updating iOS cannot restore compatibility and may worsen it; a mixed list also receives the same misleading blanket instruction.

**Suggested fix:** Give each app a reason (OS too old or OS too new). Offer an OS update suggestion only for minimum-version failures; for maximum-version failures explain that this release does not support the current OS and suggest selecting a supported app release. Keep the summary neutral for mixed failures.

## VA-009 — P2 — Choosing the previous backup deletes the current backup before consent

**Where:** `Vendor/SideStore/AltStore/My Apps/MyAppsViewController.swift:1585–1595`; restore confirmation at `:1601–1604`.

**Reachability:** Retained upstream My Apps backup menu; not SideKick's replacement Home.

**Evidence / why:** `restorePreviousBackup` first removes the current backup directory and copies the previous backup into its place. Only afterwards does it call `restore`, which asks for confirmation and offers Cancel. Cancelling therefore does not preserve the current backup: it has already been deleted. Both filesystem operations use `try!`; a missing previous backup, disk-full copy or other I/O failure crashes after deletion, potentially losing the newest recoverable data.

**Suggested fix:** Present the confirmation before mutation. Stage and validate the previous backup at a temporary destination, then replace atomically after confirmation, retaining a recoverable current backup until restoration succeeds. Catch errors and show a recovery action. Verify Cancel preserves both backups, and simulate copy failure.

## VA-010 — P2 — Checking updates waits forever when no source is available

**Where:** `Vendor/SideStore/AltStore/My Apps/MyAppsViewController.swift:1829–1836`; `Vendor/SideStore/AltStore/Managing Apps/AppManager.swift:280–282` and `:337`.

**Reachability:** Retained upstream My Apps pull-to-refresh; not SideKick's replacement Home.

**Evidence / why:** The update checker starts `fetchSources()` and then waits for `didFetchSourceNotification` before awaiting its result. The empty-source path invokes completion with `noSources` and immediately returns, bypassing the notification posted only at the end of the normal path. With an empty/recreated source store, the result is already a failure, but the notification loop never completes. The checking flag stays true, the refresh spinner never ends, and later checks return at the guard. The separate task can also complete before the async notification subscriber is installed; `async let` does not guarantee subscriber-first execution.

**Suggested fix:** Await the fetch result directly and order UI/data changes in its completion path, with deferred clearing of checking state and spinner. If a notification is retained, install the subscriber before initiating work and ensure every exit emits a terminal event. Exercise no sources and fast completion.

### VA-011 — P3 — Recommended-source failures are reported as successful empty results
- **Where:** `Vendor/SideStore/AltStore/Sources/AddSourceViewController.swift:721`, `:734–735`, `:755–761`.
- **Evidence / why:** `fetchError` is initialized but never assigned in either failed fetch completion or the catch for starting a fetch. If the known-source list loads but every recommended source fails (for example, offline endpoints), `sources` is empty and `fetchError` remains nil, so the method finishes with `.success([])`. The error footer at lines 913–922 is never presented for these failures; the recommended list disappears without an explanation or retry path. This is the retained upstream Add Source controller; the integrated native SideKick Sources screen is a separate flow.
- **Suggested fix:** Capture the first/all per-source errors under the same context serialization, report failure when none load, and expose retry while preserving successful sources when only some fail.


### VA-012 — P2 (retained upstream UI) — Failed source deep links leave the busy indicator stuck and discard the retry URL
- **Where:** `Vendor/SideStore/AltStore/Sources/SourcesViewController.swift:336–373`, especially `:342–368`.
- **Evidence / why:** `handleAddSourceDeepLink()` clears `deepLinkSourceURL` at line 342 and turns on `navigationItem.leftBarButtonItem?.isIndicatingActivity` at 344 before awaiting `AppManager.shared.fetchSource(...)` with `try` at 368. The `finish(.failure(...))` cases exist inside the local `finish` function, but there is no `do/catch` around this throwing call. If fetching or decoding fails, the unstructured `Task` ends with an error before either `finish` call, so the spinner is never stopped, no error is presented, and the URL has already been discarded. The user cannot retry from this screen without initiating the deep link again. This is the retained UIKit Sources flow; the integrated SideKick screen is separate.
- **Suggested fix:** Catch errors from `fetchSource`, pass them to `finish(.failure(error))`, and only clear/retain the URL according to a deliberate retry policy. Ensure the indicator always resets with `defer`. Exercise failed fetch followed by retry. Static analysis only; no device execution.
