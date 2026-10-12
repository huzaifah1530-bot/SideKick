# SideKick complete-file source audit — 12 October 2026

Status: in progress. Findings are appended during review; the coverage ledger records reviewed files.

Scope: current working-tree source, including uncommitted changes, build configuration, patches, tests, documentation and vendored SideStore/dependencies. Generated outputs, Git internals, downloaded reference copies and archives are inventoried separately; binary resources receive metadata/reference inspection rather than a claim of line-by-line code review. This is a static audit on Windows, not an iOS device usability test or an Xcode build.

Each finding records where, why, and what should change. P1 means a major broken/conflicting flow; P2 means a practical usability or maintenance defect; P3 means cleanup or polish. UI recommendations are identified as recommendations; suspected dead code requires reference/build evidence.

## Findings in SideKick and its build integration

### SK-001 — P2: GitHub setup and diagnostics dominate the normal Home screen

**Where:** `SideKick/Views/Home/HomeView.swift:245–293,623–651`.

**What:** The GitHub Updates section is unconditional, even for an empty library or apps without GitHub tracking. It appears above Active and Ready to Install, shows “GitHub updates aren’t configured…” for optional setup, offers a second SideKick setup row, and prints the first attention result's raw detail directly in the list. SideKick being unconfigured takes precedence over the available-update count in `updateCheckStatus`.

**Why:** Optional configuration reads as a permanent problem and pushes the actual app list down. An unrelated unconfigured SideKick record can obscure the headline that another app has an update. The first attention message lacks an app label or a direct route to fix that specific app. This is a source-backed UX recommendation, not a device-layout measurement.

**Improve:** Show a compact aggregate status only for configured sources, prioritize available updates and actionable failures, and put optional setup in app settings. Link an attention row to the named affected app; keep technical detail behind that destination.

### SK-002 — P2: Regular and LiveContainer app rows use separate visual and action conventions

**Where:** `SideKick/Views/Home/HomeView.swift:319–375,559–598`; `SideKick/Views/LiveContainer/LiveContainerViews.swift:16–58,118–128`.

**What:** Regular apps use 56-point icons, 8-point vertical padding plus horizontal padding, “Version …”, an expiry badge, and the custom navigation-indicator modifier. LiveContainer rows use 50-point icons, 4-point padding, a different version/build string, additional storage rows, and omit the navigation-indicator modifier. Both context menus call an action “Refresh”, but one renews signing while the other merely rescans folder metadata.

**Why:** Users see different density, affordances and terminology for two types of apps in the same list. Signing expiry should remain specific to signed apps, but the surrounding row design need not diverge. Identical Refresh labels promise different effects.

**Improve:** Share an app-row component with optional status/metadata slots and consistent icon, spacing, navigation and Open labels. Name the guest action “Rescan” or “Refresh Metadata”; preserve type-specific signing and handoff capabilities.

### SK-003 — P2: Home always shows an irrelevant LiveContainer empty section

**Where:** `SideKick/Views/Home/HomeView.swift:377`; `SideKick/Views/LiveContainer/LiveContainerViews.swift:60–78`.

**What:** The LiveContainer section is always inserted. With no configured connections or guests it displays “No cached guest apps were found” and Manage Connections, including for people who do not use LiveContainer.

**Why:** An optional integration creates a permanent empty-state message in the main app list. “Cached guest” describes implementation details rather than the user's next step.

**Improve:** Hide the section until linked or show a single optional “Connect LiveContainer” entry in Add App/settings. For linked-but-empty folders, say “No apps in this folder” and offer Rescan/Choose Folder.

### SK-004 — P3: Home retains a no-op filtered update abstraction

**Where:** `SideKick/Views/Home/HomeView.swift:227,663–665`.

**What:** `filteredGitHubUpdates` returns `githubUpdates` unchanged and is used only to iterate the same list.

**Why:** The name implies filtering that no longer occurs, complicating tracing of queue visibility and encouraging assumptions about which candidates are excluded.

**Improve:** Use `githubUpdates` directly or implement/document the specific filtering rule if one is intended.

### SK-005 — P2: Refresh All's result does not identify failures or offer recovery

**Where:** `SideKick/Views/Home/HomeView.swift:538–554,697–722`.

**What:** The completion alert reports only succeeded/attempted counts, with a single OK button. All-failed and partial-failure cases provide neither affected app names nor a retry action.

**Why:** The user cannot tell which app still risks expiration without checking each app. “Refresh your apps and try again” after zero attempts is circular advice.

**Improve:** Preserve per-app results from the refresh service and show a result list with concise causes, reconnect actions and Retry Failed. Keep successful completion unobtrusive.

### SK-006 — P2: LiveContainer connection setup exposes technical choices before the normal folder action

**Where:** `SideKick/Views/LiveContainer/LiveContainerViews.swift:149–160,176–190`.

**What:** Linking requires a name, storage-kind picker and editable URL scheme before selecting the folder. A long footer explains private App Groups, schemes, snapshots and verification. “Select a Different Directory” creates a separate connection rather than changing the displayed one.

**Why:** The common task of linking a folder starts with implementation vocabulary. The latter action's wording suggests replacement but retains the old connection and its cached apps, requiring a second disconnect step.

**Improve:** Lead with Choose LiveContainer Folder; infer/default standard values and reveal advanced settings when needed. Rename the additive action “Add Another Directory”, and offer an explicit replace flow with a review of retained metadata/source associations.


### SK-007 — P3: Unreachable import and recommendation code remains in the first-party UI

**Where:** `SideKick/ViewModels/HomeViewModel.swift:30–40`; `SideKick/Views/Library/GitHubUpdateSettingsView.swift:95,275–280,292–318`; `SideKick/DesignSystem/SideKickTheme.swift:7,29–35`.

**What:** Repository reference searches find no caller for `HomeViewModel.importIPA(from:)`, `legacyKey(for:)`, `sideKickInk`, or `sideKickGlass`. The private baseline picker is constructed only with `recommendedKey: nil`, so its suggested-version branch cannot execute. Home imports through prepare/review/save instead of the old immediate-save view-model method.

**Why:** These leftovers suggest capabilities or migration behavior the active flow does not have. The README's suggestion/glass claims can be confused with real reachable UI. Keeping the old import method also offers a second route that bypasses the installed-target review if reused later.

**Improve:** Remove the unused helpers and impossible recommendation branch, or connect them through an intentional reviewed flow. Keep documentation aligned with reachable behavior. This finding concerns the current repository reference graph, not externally callable library API.

### SK-008 — P2: Files import sets loading state that the UI never displays or uses

**Where:** `SideKick/ViewModels/HomeViewModel.swift:8`; `SideKick/Views/Home/HomeView.swift:463–470,764–773`.

**What:** `viewModel.isImporting` is written before reading the IPA and reset afterward, but no view reads it. Files import has no reading indicator and the Add App controls are not disabled by that state.

**Why:** Large archives can appear to do nothing while metadata is extracted. Repeated imports can overlap and overwrite the single `ipaAwaitingUpdateChoice`/matching-installations state, making the review correspond to a different import than expected.

**Improve:** Show Reading IPA progress, serialize prepared-import review, and temporarily disable/reject another import until the current choice completes. Remove the write-only state only if another explicit state replaces it.

### SK-009 — P2: Install and refresh consoles duplicate the same layout and foreground technical logs

**Where:** `SideKick/Views/Library/AppManagementView.swift:552–671,927–1055`.

**What:** Both consoles independently implement the same title/progress block, timestamped monospaced scrolling log, scroll-to-bottom behavior, failure text, hidden navigation, Done/Close button, and progress logging threshold.

**Why:** UI fixes, Dynamic Type behavior, recovery buttons and message handling must be applied twice. Normal users must read pipeline/account logs to understand a routine operation; failures offer Close rather than a targeted recovery action. The duplicated views also maintain separately worded install/update/refresh states.

**Improve:** Extract a shared operation-status presentation with a short friendly stage summary, optional expandable activity log, and error-specific Retry/Reconnect actions. Keep operation execution and callbacks separate from the shared view.

### SK-010 — P2: Account selection uses a stale value snapshot after reconnecting

**Where:** `SideKick/Views/Library/AppManagementView.swift:879–924`; `SideKick/Views/Library/GitHubUpdateDetailView.swift:73–75,335–343`.

**What:** `InstallAccountSelectionView` takes `let accounts` and routes disconnected entries to account detail; it does not reload its account list on return. GitHub update detail copies `accountStore.accounts` into `eligibleAccounts` and `account` in a `.task`, without refreshing those copies on reappearance/account changes. Its foreground handler only validates downloads.

**Why:** Reconnecting the correct account inside the offered recovery path can leave the originating update page still displaying Reconnect or its picker still using `hasSavedSession == false`. Users may need to leave and reopen the entire update flow.

**Improve:** Derive selections from the observable account store, reload on return/account-change notification, and reconcile the selected account by stable account/team identity. Verify reconnect-and-return on device.

### SK-011 — P2: Regular update and guest update screens have divergent controls and download feedback

**Where:** `SideKick/Views/Library/GitHubUpdateDetailView.swift:102–329`; `SideKick/Views/LiveContainer/LiveContainerViews.swift:299–332`.

**What:** Regular updates offer token selection, build history, byte/percentage progress, download-again and confirmation before skipping. Guest updates offer a compact latest-only section, a progress bar only when total size is known, no cancel/download-again control, and immediate Skip This Build without confirmation. Regular action text says Install New IPA even though it only starts a download; the guest action says Update in LiveContainer before opening a share sheet.

**Why:** The same GitHub tracking/download backend appears to support different capabilities depending on app type. Unknown-length guest downloads show little feedback, and users cannot predict whether pressing an action downloads, installs or asks them to select a recipient.

**Improve:** Share update-status/download controls and vocabulary across target types, including unknown-size feedback, cancel/retry and skip confirmation. Use Download IPA for the first step, then Update App or Send to LiveContainer as the type-specific final action. Retain the necessary external-install confirmation for guests.

### SK-012 — P2: GitHub token recovery sends users out of the active import flow

**Where:** `SideKick/Views/Library/GitHubTokenPickerView.swift:11–21`; `SideKick/Views/Library/GitHubUpdateDetailView.swift:102,419–432`.

**What:** The token picker only offers existing tokens and text telling users to add/edit in Settings. Actions download requires a token, but the picker has no Add Token or Manage Tokens navigation from the import/update context.

**Why:** A first-time Actions import fails at the point of download and sends users back through the main tabs to create a credential, then repeat navigation. The existing token editor can already support this recovery in place.

**Improve:** Add Add Token and Manage Tokens destinations to the picker, reload credentials on return, and select a newly saved token. Explain the needed permission next to the Actions choice before starting a transfer.

### SK-013 — P2: Skipped Updates displays internal identity strings instead of app/build names

**Where:** `SideKick/Views/Settings/SkippedGitHubUpdatesView.swift:18–30`; `SideKick/Models/LiveContainerModels.swift:40–43`; `SideKick/Models/GitHubUpdateConfiguration.swift:116`.

**What:** Rows use the target bundle identifier as their title and print the raw dismissed update key. Guest targets contain a connection UUID and base64 folder name; build keys contain numeric IDs and encoded revision data.

**Why:** The user cannot readily recognize the app or skipped release to undo. Two guest entries from different folders look like machine-generated data rather than apps.

**Improve:** Resolve titles from the installed/guest catalogues, retain a human-readable build label when skipping, and show repository/date as secondary metadata. Put full identifiers behind a disclosure for diagnostics and use readable fallback names for missing apps.

### SK-014 — P2: GitHub update notifications have no route to the affected app

**Where:** `SideKick/Services/GitHubUpdateNotificationScheduler.swift:42–46,82–92`; `SideKick/Views/Root/ContentView.swift:1–146`.

**What:** Notifications include target IDs/update keys in userInfo, but SideKick's notification delegate implements only foreground presentation. There is no response handler in first-party code that consumes those values to navigate to the corresponding update or guest.

**Why:** Tapping an app-specific update notification opens the general app experience and requires the user to locate the app again. The stored routing metadata is unused by the active root UI.

**Improve:** Handle notification responses in the actual integrated bootstrap/delegate, validate the current target/source and publish a pending navigation request to ContentView. Open the current detail/update when still available, with a friendly fallback if already resolved. Verify the integration delegate assignment before changing it.

### SK-015 — P3: Obsolete GitHub comparison and API helpers duplicate the current implementation

**Where:** `SideKick/Services/GitHubUpdateService.swift:57–80`; `SideKick/Models/GitHubUpdateConfiguration.swift:13–32`; `Tests/SideKickCoreTests/GitHubBaselineTests.swift:14–17`.

**What:** `candidate(for:)`, private `legacyReleaseKey(for:)` and `parseGitHubDate` have no production callers. `GitHubBuildComparison` is exercised only by old baseline tests; production checks use `GitHubTrackingPolicy` and v2 build keys. Date parsing is now performed in GitHubHistoryClient, and the legacy release-key converter also appears in the unused settings helper.

**Why:** Test-only legacy code can give misleading confidence about production build ordering, while dead methods increase the work needed to understand an already sensitive baseline system.

**Improve:** Remove obsolete internal methods and comparison policy, migrate any genuinely needed historical compatibility into the current policy, and test that actual production path. Preserve persisted-record compatibility deliberately rather than leaving unused helpers as evidence of support.

### SK-016 — P2: Onboarding makes an optional daily automation mandatory

**Where:** `SideKick/Views/Root/RequiredSetupView.swift:115–120,287–299,444–464`; `SideKick/Views/Root/ContentView.swift:16–30`.

**What:** Finish Setup requires `refreshAutomationsConfigured`; the last page has no Not Now. The only confirmation is “I’ve Added the Shortcut”, which cannot establish that a daily automation was created. Until confirmed, the whole app remains behind setup.

**Why:** Users who prefer manual refresh cannot reach their library without claiming to have done an optional action. Installing a shortcut is also distinct from scheduling its automation, so the mandatory flag does not prove the reliability the flow implies.

**Improve:** Make scheduling an optional final recommendation with Skip/Do Later, keep device/signing prerequisites scoped to operations, and distinguish Shortcut Added from Automation Created. Offer the scheduling guide again in App Refresh settings.

### SK-017 — P2: Fixed remote pairing ports can only be entered by stepping through 65,535 values

**Where:** `SideKick/Views/Settings/SideStoreSettingsPages.swift:153–156`.

**What:** The remote pairing port uses a Stepper from zero to 65,535 without an editable numeric field or explicit Automatic option.

**Why:** Entering a known five-digit port requires thousands of increments; resetting it to Automatic is equally awkward. This makes the advanced recovery feature practically unusable.

**Improve:** Provide an Automatic toggle and a validated numeric field for fixed ports (1–65,535), with Done/Apply. Keep increment controls only as a secondary fine adjustment.

### SK-018 — P2: Pairing recovery instructions still assume the built-in VPN

**Where:** `SideKick/Views/Settings/SideStoreSettingsPages.swift:218–223`; `SideKick/Views/Settings/LocalConnectionSettingsView.swift:132–136`.

**What:** Failed pairing verification instructs users to “Allow SideKick’s Local Connection in Settings”, and Connection Help says to choose “Allow Local Connection”. The actual default is external LocalDevVPN and the built-in permission button is named “Allow Built-in VPN”.

**Why:** Standard/free-account installs cannot follow the named permission action and need to connect LocalDevVPN instead. The stale instructions point to a control that does not exist under that name.

**Improve:** Build recovery messages from the selected mode, use the exact current button labels, and link directly to Connect LocalDevVPN or built-in permission as applicable.

### SK-019 — P2: Bulk storage removal silently deletes pending update records as well as copies

**Where:** `SideKick/Views/Settings/SideStoreSettingsPages.swift:281–293,333–340,366–372`; `SideKick/Services/IPAImportStore.swift:374–383`.

**What:** “Remove downloaded IPA copies” calls `ipaImportStore.delete` for every imported record with a fileName. That deletes the library/index record too, including queued manual/GitHub/guest update metadata; it does not just remove the on-disk file. The confirmation says only that IPA files are removed and installed apps remain.

**Why:** A storage cleanup action can unexpectedly remove the user's pending-update queue or Ready to Install entries. Installed apps are safe, but the relevant workflow consequence is omitted.

**Improve:** Explain the number of queued/ready entries affected before removal, allow review/selection, or keep metadata with an explicit Needs Download Again state when the intended action is to free cached bytes.

### SK-020 — P2: Home prompts for a disconnected local tunnel during ordinary browsing

**Where:** `SideKick/Views/Root/ContentView.swift:40,46,85–103`; `SideKick/Services/LocalVPNService.swift:38–58,63–82`.

**What:** At startup/foreground, ContentView checks local connection availability and presents a modal Connect LocalDevVPN/permission alert even before the user attempts install, refresh or JIT. The acknowledgement is only an in-memory flag, so a new process may prompt again. The alert explicitly says users can keep browsing.

**Why:** The message interrupts a task that does not require the tunnel and can compete with initial setup alerts. “Not Now” does not establish a persisted browsing preference. This is precisely a case of an inconvenient message shown immediately on the main experience.

**Improve:** Show operation-specific connection recovery when needed; keep a quiet connection status in Settings or next to actions requiring it. Avoid startup modals for optional browsing prerequisites, and integrate the requirement into onboarding only at its connection step.

### SK-021 — P2: Forgetting a LiveContainer connection is not coordinated with source cleanup

**Where:** `SideKick/Views/LiveContainer/LiveContainerViews.swift:214–217`; `SideKick/Services/LiveContainerStore.swift:231–242`.

**What:** Forget first deletes all guest/catalogue records, then removes GitHub settings one guest at a time. If a source-store write fails partway, the connection has already disappeared and the only list of IDs came from the completed forget call. The UI offers an error but no operation record/retry for the remaining cleanup.

**Why:** Orphaned source settings can survive a supposedly complete Forget, including entries on Skipped Updates. The user cannot retry the original action because its connection no longer exists. By contrast, Remove Cached Guest deliberately removes its source before its catalogue row.

**Improve:** Coordinate deletion with a durable pending-cleanup record or transaction/retry operation, or clear source settings before removing the connection while retaining a recoverable list on failure. Include queued guest IPA/download cleanup in the same explicit policy.

### SK-022 — P2: Every guest launch rescans all apps and icons in the linked folder

**Where:** `SideKick/Services/LiveContainerStore.swift:247–273`; `SideKick/Services/LiveContainerScanner.swift:10–49`.

**What:** `launchURL(for:)` calls the full directory scanner for one guest. The scanner enumerates/sorts every child, parses every app's metadata and reads up to 32 MiB of icons, then launch looks up just the selected guest.

**Why:** Tap-to-open latency scales with the whole library and file-provider speed. The launch validation is valuable, but collecting unrelated icons and metadata for a single target adds avoidable work.

**Improve:** Add a targeted read/validation operation for the selected folder with the same ownership, cancellation and access-revision guards. Leave whole-library/icon discovery to explicit/background rescans.

### SK-023 — P2: IPA metadata review loads the entire executable into memory

**Where:** `SideKick/Services/IPAImportStore.swift:476–483`; `SideKick/Models/GitHubBuildTracking.swift:112–132`.

**What:** IPA import concatenates every executable ZIP chunk into a Data value to obtain an LC_UUID. The UUID reader needs only the Mach-O header and load commands. The importer also accumulates plist/icon data without the size budgets used by LiveContainerScanner.

**Why:** Large executables can produce a large peak memory allocation during a routine Files import, then repeat during fileURL identity validation. This makes a mobile import/review flow slower and vulnerable to memory pressure despite not needing the full binary content.

**Improve:** Stream/limit extraction for metadata with sensible plist/icon/load-command budgets, stop retaining bytes once the UUID-relevant commands are available, and preserve malformed/unsupported-binary fallback as unverified. Validate large IPA imports under device memory pressure.

### SK-024 — P3: Temporary IPA copy/validation and cleanup logic is repeated in several branches

**Where:** `SideKick/Services/IPAImportStore.swift:286–303,336–350,357–372`; `SideKick/Services/GitHubUpdateService.swift:113–158`; `SideKick/Services/GitHubUpdateDownloadStore.swift:35–85`.

**What:** fileURL repeats temporary-copy, readMetadata, metadataMatches, remove-on-error and source-missing translation in retained/migration/bookmark branches. GitHub Actions extraction removes the same download in explicit success/error paths and again in defer; the download store also removes its temporary file in defer and after the do/catch.

**Why:** Ownership and cancellation behavior are harder to verify because the same cleanup appears at multiple levels. Changes to identity validation or error translation can drift between branches.

**Improve:** Introduce a single temporary validated-copy helper and one clearly documented cleanup owner per resource. Keep persist/migration logic separate, and use defer once where its lifetime covers every relevant exit.

### SK-025 — P2: Expiration reminders can say “2 days” when expiry is much sooner

**Where:** `SideKick/Services/ExpirationNotificationScheduler.swift:56–61`.

**What:** If an app is already inside its two-day warning window, the notification is scheduled one second from now but its title is always “expires in 2 days”. An app expiring in an hour therefore gets that same title.

**Why:** The message gives a falsely reassuring deadline precisely when action is urgent. Home/details already calculate actual remaining time.

**Improve:** Use a relative/actual deadline for immediate reminders (“expires today” or the exact expiry time), and use the two-day wording only when the trigger truly corresponds to two days before expiry.

### SK-026 — P2: Adding an Apple account has no visible ongoing status on the Accounts page

**Where:** `SideKick/Views/Accounts/AccountsView.swift:9–65,88–100`; `SideKick/Services/SigningAccountStore.swift:27,140–217`.

**What:** The credential sheet dismisses and a Task starts authentication. Accounts disables its Add button while working but does not show progress or the store's signInCheckpoint. The onboarding account page does show a sign-in ProgressView, so the same operation has different feedback depending on entry point.

**Why:** Between sheet dismissal and upstream authentication/team prompts, users can interpret the action as having done nothing. Long authentication/save stages lack a visible explanation.

**Improve:** Show a consistent Signing In status in both entry points, using friendly stage summaries rather than the technical persisted checkpoint. Preserve retry/reconnect guidance for failures.

### SK-027 — P2: Signing-certificate export picks a recipient account by ambiguous name matching

**Where:** `SideKick/Services/SigningAccountStore.swift:443–458`; `SideKick/Services/SideKickCertificateExport.swift:12–18,27–37`.

**What:** Certificate export chooses the first installed app whose name or bundle identifier contains “LiveContainer”. With multiple installations, or another app containing that substring, the selected signing account can be different from the intended LiveContainer. The consent alert says only “your certificate” and “an external app”, without naming the account/team or actual callback destination.

**Why:** The user cannot review which signing authority is being shared or which app/endpoint receives it. This is both a clashing identity heuristic and an unclear sensitive-action flow.

+**Improve:** Resolve an explicit installation/account identity, present a selector when multiple qualify, and show account/team plus validated destination in the consent screen. Restrict callbacks to the expected handoff contract rather than substituting into an arbitrary template.

### SK-028 — P2: The refresh shortcut reports success even when its operation failed

**Where:** `SideKick/Services/DailyRefreshShortcut.swift:11–14,35–44`; `SideKick/Services/SideStoreOperationService.swift:339–382`.

**What:** The AppIntent always returns `.result()`. Its private runner swallows startup/connection errors and also returns silently for a zero/partial-success outcome; only a debug log reveals why no refresh occurred. The timestamp prevents duplicate success runs, but the invoking Shortcuts action receives no failure signal or result counts.

**Why:** The scheduled automation can look successful in Shortcuts while no signing was renewed. Silence is reasonable for routine background work, but discarding machine-readable status removes an opportunity for targeted retry and diagnosis.

**Improve:** Return a structured outcome to the intent, distinguish already refreshed/no eligible apps/partial failure/connection unavailable, and let automation handle failure without unnecessary foreground alerts. Keep successful background runs quiet.

### SK-029 — P2: Storage preparation failure is cached permanently, so Try Again cannot recover

**Where:** `SideKick/Services/SideKickDataDirectory.swift:6–54`; `SideKick/Views/Root/ContentView.swift:126–129`; `patches/sidestore-sidekick.patch:FileManager+SharedDirectories integration`.

**What:** The private storage URL is a once-evaluated `static let` that catches migration/directory errors and returns nil. Database Try Again calls startDatabase but the integrated shared-directory accessor returns the same cached nil.

**Why:** A transient storage/file-protection/migration error cannot be retried in the same process, despite the UI offering a retry button. The only diagnostics are logged; the original preparation error is not preserved in the URL API.

**Improve:** Keep the successful URL stable once the database opens, but make failed preparation explicitly retryable before opening it. Preserve and display a concise preparation failure cause, or tell the user to relaunch if retry truly requires a new process.

### SK-030 — P2: Bulk cache cleanup repeatedly rescans and remeasures the whole cache

**Where:** `SideKick/Services/SideKickStorageCleanup.swift:174–189,204–213`; `SideKick/Services/SideKickStorageUsage.swift:29–39`.

**What:** Clean Unused gets a full measured item list, then each item's remove call invokes `items()` again with size measurement for every remaining item. Storage measurement separately traverses nested directories multiple times (Library, total container, signing/import folders, and Temporary).

**Why:** Cleaning n source directories performs roughly n complete enumerations and repeated recursive size calculations. On large signing caches this adds avoidable I/O and delays the user's cleanup, even though removal primarily needs current ownership/protection checks.

**Improve:** Revalidate the individual target and current ownership immediately before deletion without remeasuring unrelated files; acquire appropriate cleanup ownership for the batch. Calculate storage category totals in a single traversal and reuse them for the displayed breakdown.

### SK-031 — P3: A full CIDR validation subsystem is compiled but unused by the tunnel

**Where:** `SideKickVPN/CIDRValidator.swift:80–403`; `SideKickVPN/TunnelConstants.swift:15`; `SideKickVPN/PacketTunnelProvider.swift:89–90`; `scripts/embed-local-vpn.py:35`.

**What:** The VPN target compiles CIDRValidator, its parse-result/error/category types and formatting/conversion helpers, but repository references outside their own definitions use only CIDREndpoint. `defaultAllowIntermediateAddresses` is never consumed. The provider uses CIDREndpoint's permissive initializer instead of the included validator.

**Why:** Most imported validation code is dormant, while its presence suggests network options are validated. Invalid prefixes silently fall back and IP strings are not validated by that initializer. Defaults currently supplied by SideKick are fixed valid values, so this is primarily a cleanup/contract issue rather than a claim that ordinary connections fail.

**Improve:** Either validate the provider input through a small relevant entry point or retain only the endpoint/mask code required by the fixed local tunnel. Preserve upstream notices when trimming derived code.

### SK-032 — P2: The standalone project configuration clashes with the actual integrated app

**Where:** `project.yml:11–45`; `SideKick/App/SideKickApp.swift:5–13`; `patches/sidestore-sidekick.patch:App/SideKickApp.swift exception and SceneDelegate replacement`; `.github/workflows/ios-build.yml:83–95`; `scripts/embed-local-vpn.py:153–159`.

**What:** project.yml defines a standalone app with only ZIPFoundation, Swift 6 and version 1.0.0, compiling sources that import SideSign/Minimuxer and reference SideStore types. The working CI builds SideStore's target with those dependencies and excludes SideKickApp.swift; its initializer's separator appearance and SideKick notification delegate assignment therefore never run in the delivered IPA. The integration script independently stamps version 0.8.0.

**Why:** Two apparent build entry points describe different products; the standalone one lacks the engine required by current source. Bootstrap/UI initialization can be added to the excluded app struct and have no effect on the actual build. Version/Info.plist/delegate changes easily drift between these paths.

**Improve:** Remove or explicitly mark the obsolete standalone config, or make it generate the real integrated target. Put required initialization in the active SceneDelegate/AppDelegate integration and use one authoritative version/configuration source. Treat @main/delegate helpers as dormant in the current packaged product.

### SK-033 — P2: The native bootstrap requests notifications before optional onboarding consent

**Where:** `Vendor/SideStore/AltStore/AppDelegate.swift:108,211,382`; `patches/sidestore-sidekick.patch:last hunk`; `SideKick/Views/Root/RequiredSetupView.swift:311–329`.

**What:** The actual AppDelegate calls prepareForBackgroundFetch on launch, which still calls notification requestAuthorization unconditionally. SideKick's notification onboarding page later offers Allow Notifications/Not Now, but the system prompt has already been requested. The integration patch only inserts fetch-interval selection above the upstream request.

**Why:** Permission appears before the user receives SideKick's rationale and undermines the optional onboarding flow. Denial then leads through a second page to iOS Settings.

**Improve:** Keep fetch registration independent from notification permission; request notifications only after the onboarding/user action, and handle existing permission state passively at startup.
