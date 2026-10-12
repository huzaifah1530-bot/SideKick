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
