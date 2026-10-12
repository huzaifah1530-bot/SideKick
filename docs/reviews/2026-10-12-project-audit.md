# SideKick complete-file source audit — 12 October 2026



Status: source review and inventory reconciliation complete. Findings were appended during review and consolidated below. Coverage verification has zero missing project paths.



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



**Where:** `SideKick/Services/GitHubUpdateNotificationScheduler.swift:42–46,82–92`; `SideKick/Views/Root/ContentView.swift:1–146`; active bootstrap `Vendor/SideStore/AltStore/AppDelegate.swift:108,717–721`.



**What:** Notifications include target IDs/update keys in userInfo, but the actual integrated AppDelegate assigns itself as the notification delegate and implements only foreground presentation. Neither that delegate nor the first-party root consumes notification responses to navigate to the corresponding update or guest.



**Why:** Tapping an app-specific update notification opens the general app experience and requires the user to locate the app again. The stored routing metadata is unused by the active root UI.



**Improve:** Handle notification responses in the actual integrated bootstrap/delegate, validate the current target/source and publish a pending navigation request to ContentView. Open the current detail/update when still available, with a friendly fallback if already resolved. The active delegate assignment has been checked against the integrated bootstrap.



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



**Improve:** Resolve an explicit installation/account identity, present a selector when multiple qualify, and show account/team plus validated destination in the consent screen. Restrict callbacks to the expected handoff contract rather than substituting into an arbitrary template.



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



## Consolidated vendor findings — SideSign library

Scope: every file in Vendor/SideStore/Dependencies/SideSign. Full text reads are recorded in the separate SideSign coverage ledger. CLI-only findings are labelled separately from the library integrated into SideKick. No production changes.

### SS-001 — P1: Downloaded Anisette libraries are extracted even after a checksum mismatch

**Where:** `Vendor/SideStore/Dependencies/SideSign/Sources/Anisette/AnisetteDataManager.swift:629–645`.

**What:** When supplied SHA-256 differs from the downloaded payload, the manager only logs “Proceeding with extraction” and unzips/loads the package. The matching sha256Mismatch error type exists but is not thrown here.

**Why:** Integrity validation and actual flow clash: modified/damaged native libraries are accepted despite explicit evidence they are not the expected payload. The later file-existence check does not validate content.

**Improve:** Reject the mismatch before writing/extracting, retain the previous working library set, and surface a concise retry/source error. Stage and validate the complete package before promoting it to the active cache.

### SS-002 — P2: Concurrent library-cache callers can return success after another request failed

**Where:** `Vendor/SideStore/Dependencies/SideSign/Sources/Anisette/AnisetteDataManager.swift:235–258,612–620,690–708`.

**What:** This unchecked-Sendable singleton has unsynchronized mutable isCaching, localProvider and remoteCache. If isCaching is true, downloadAndCacheLibs waits for it to become false and returns without checking that the other operation succeeded or even targeted the same directory/source. Errors are not shared with waiters.

**Why:** A waiting setup can look successful despite no usable libraries, or reuse a provider created for different request context. Concurrent calls also race on the unsynchronized cache state.

**Improve:** Actor-isolate the manager and coalesce requests with an owned Task keyed by source/target settings; await its actual result and revalidate the requested library set. Scope provider caching to the directory/provisioning/client identity it represents.


### SS-003 — P1: ZIP extraction does not enforce destination containment

**Where:** `Vendor/SideStore/Dependencies/SideSign/Sources/Archiver/FileManagerZip.swift:28–60`; `Sources/Anisette/AnisetteDataManager.swift:642`.

**What:** unzipArchive appends the archive-supplied filename directly to the destination, creates its parents and writes the file. It never rejects traversal components, absolute/escaped paths, symlink ancestors or resolved paths outside the extraction root.

**Why:** A crafted archive can overwrite other writable app files instead of remaining inside its staging/cache directory. The same routine handles downloaded native Anisette libraries and app-bundle extraction.

**Improve:** Validate every canonical destination against an owned extraction root, reject escaping/absolute paths and symlink traversal, bound sizes/entry counts, and stage extraction before promotion. Apply checks in the shared routine rather than only a UI importer.

### SS-004 — P2: ZIP readers accept incomplete catalogues and writers can trap at format limits

**Where:** `Vendor/SideStore/Dependencies/SideSign/Sources/Archiver/Archive.swift:290–323,430,481,537,544–555`.

**What:** Central-directory parsing breaks and returns the entries parsed so far on a truncated header, wrong magic or short filename. Writer converts data/file-name/entry-count/offset values directly to UInt32/UInt16 without bounds checks or ZIP64 support.

**Why:** A damaged archive can look like a successful partial extraction. A large app or a bundle with more than 65,535 entries can trap during ordinary packaging instead of returning a recoverable error. Full-entry allocation also amplifies memory pressure for large files.

**Improve:** Reject any catalogue shorter than its declared records, validate local/central lengths consistently, and explicitly reject unsupported ZIP64/oversized values with actionable errors or implement the format. Stream file data where practical.

### SS-005 — P2: App ZIP creation suppresses finalization errors and deletes the previous output first

**Where:** `Vendor/SideStore/Dependencies/SideSign/Sources/Archiver/FileManagerZip.swift:129–171`; `Sources/Archiver/Archive.swift:363–366,512–560`.

**What:** zipAppBundle returns without calling writer.close; deinit performs try? close. Failure to write/synchronize the central directory is discarded. Existing output is removed before the replacement has been built. The sibling zipDirectory explicitly closes and propagates errors.

**Why:** Packaging can report success with a corrupt IPA, and a failed replacement can leave no previous usable export. Two nearly identical packaging APIs have different failure contracts.

**Improve:** Close explicitly before success, build to a temporary sibling and atomically replace the final IPA only after finalization succeeds. Share that finalization/ownership path between packaging APIs.


### SS-006 — P2: Legacy PKCS#12 detection mistakes any ASN.1 sequence for a certificate/key archive

**Where:** `Vendor/SideStore/Dependencies/SideSign/Sources/Compatibility.swift:154–157`; `Sources/Certificates/CertificateParser.swift:13–17`.

**What:** Data.isPKCS12 checks only whether the first parsed TLV has sequence tag 0x30, a tag also used by ordinary DER certificates and other ASN.1 structures. extractDER accepts a boundaryKeyword but never uses it when decoding PEM.

**Why:** The compatibility helper's name promises format identification while it only recognizes a general container, and the boundary selector is misleading. Callers can enter the wrong parser or accept the wrong PEM block and produce confusing import failures.

**Improve:** Validate the PKCS#12 PFX schema/version before classification, and honor/validate PEM block boundaries or remove the unused argument. Keep format errors distinct from a missing private key.

### SS-007 — P1: Authentication explicitly writes the unredacted session token to verbose logs

**Where:** `Vendor/SideStore/Dependencies/SideSign/Sources/DeveloperPortal/Authentication.swift:179–187`.

**What:** After decrypting the authentication result, the code interpolates idmsToken directly into verboseLog. Several error branches also package complete decrypted dictionaries as error payloads.

**Why:** Enabling diagnostic logging can persist credential material alongside normal troubleshooting messages. This conflicts with secure account storage and makes sharing logs hazardous. Exact downstream log/error rendering is checked separately; this line itself supplies the secret unredacted.

**Improve:** Log only stage/status and a non-secret correlation ID. Redact tokens/passwords/provisioning blobs in every payload before logging or including it in a user-visible error.



## SS-008 — Failed HTTP operations can be reported as successful deletions (P2, clashing success/error handling)

**Where:** `Vendor/SideStore/Dependencies/SideSign/Sources/DeveloperPortal/DeveloperPortalAPI.swift:352–360, 464–475, 500–505`.

**What and why:** Neither request dispatcher requires a successful HTTP status before accepting an empty response. In the services dispatcher, any DELETE with an empty body returns `EmptyResponse`, including HTTP 401/403/500. Its decoding catch also returns success for a DELETE whose error body cannot decode to the requested type. The plist dispatcher likewise accepts an empty body whenever the requested type is `EmptyResponse`, regardless of status. Device/profile deletion functions then return `true`. An expired session or server failure can therefore appear to have removed a portal object even though it remains, encouraging retries and leaving local and remote state inconsistent.

**Improve:** Validate HTTP success before applying the successful-empty-response exception. Preserve status and decoded server error in failures; only accept no content for successful responses. Cover failed empty-body DELETE and malformed error-body DELETE when fixing this.


## SS-009 — App ID serialization drops capability state (P2, clashing model contract)

**Where:** `Vendor/SideStore/Dependencies/SideSign/Sources/Models/AppID.swift:17–18, 39–70`.

**What and why:** The public Codable model decodes `features` but never encodes it, and its `entitlements` property is excluded from both coding keys and decoding (always reset to an empty dictionary). Encoding and decoding an AppID silently loses capability data even when the caller expects a complete model snapshot. This is a library contract defect; the active app impact depends on which callers persist this public type, rather than proof that every install is affected.

**Improve:** Separate portal request DTOs from persisted models, or preserve every modeled field in Codable. Add a round-trip check with nonempty features and entitlements when correcting the contract.


## SS-010 — Server errors expose raw response payloads as user messages (P2, inconvenient messages)

**Where:** `Vendor/SideStore/Dependencies/SideSign/Sources/Models/Errors.swift:73–95`; producers `Sources/DeveloperPortal/DeveloperPortalAPI.swift:392–394, 506–508`.

**What and why:** `ServerError.errorDescription` includes the entire raw server payload, JSON/XML body, or missing internal key. Callers presenting localized errors can display a long HTML gateway page or technical authentication response directly to users. It also duplicates the raw body already printed to diagnostics, making ordinary error UI harder to understand and increasing accidental exposure of response data. This is the dependency's message contract; presentation varies by caller.

**Improve:** Give users a short explanation and recovery action (retry, reconnect account, or inspect details). Retain a bounded, redacted diagnostic body in a separate details/log channel instead of embedding it in every localized error.


## SS-011 — Unused authentication DTOs duplicate the live dictionary protocol and drift from it (P3, dead/duplicate/clashing code)

**Where:** `Vendor/SideStore/Dependencies/SideSign/Sources/DeveloperPortal/AuthModels.swift:11–125`; active dictionary protocol in `Authentication.swift:68,121,135` and `AppGroups.swift:80`.

**What and why:** Repository-wide Swift reference searches find these request/response types only in their declarations and relationships inside AuthModels.swift. Authentication and group assignment instead build dictionaries directly. The unused Codable response/request types already use lowercase `b`, `m1`, and `m2`, while the live protocol reads `B`/`M2` and sends `M1`. Reusing the apparently authoritative typed model would encode/decode a different protocol. They are unused in this checkout, not proven removable for all external clients of the public library.

**Improve:** Either migrate the live implementation to tested DTOs with exact CodingKeys and one protocol definition, or deprecate/remove the unused models with a public API compatibility decision. Avoid maintaining a second misleading schema.


## Consolidated vendor findings — AltStore engine and retained UIKit UI

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


## Consolidated vendor findings — SideStore engine and settings

Scope: `Vendor/SideStore/SideStore` (211 source files), with build workflow and SideKick integration patch read for reachability. Audit only; no production files changed. Findings distinguish active engine paths from retained upstream UI.



## VS-001 — P1 — Pairing migration deletes the only pairing record after failed conversion or write



**Where:** `Vendor/SideStore/SideStore/MaintenanceManager.swift:217–228` (`migratePairingFiles`), maintenance completion at lines 82–83; reached from `Vendor/SideStore/AltStore/AppDelegate.swift:194` during boot.



**Why / trigger:** A nonempty legacy `ALTPairingFile.mobiledevicepairing` is parsed with `try?` under each protocol and new files are written with `try?`. The legacy record is then removed unconditionally even if neither parser accepted it or a destination write failed. The maintenance counter is subsequently advanced to 7 regardless of success. A transient write error therefore destroys the only recoverable valid pairing file; a format that this version cannot parse is also lost instead of retained for repair. The next launch cannot retry the migration and users must regenerate their pairing record.



**Suggested fix:** Make conversion and writes throw or return explicit success, verify at least one valid persisted replacement before deleting the legacy file, and advance this maintenance pass only when its required work succeeds. Preserve the original and show an actionable migration failure when conversion is impossible. Validate malformed/nonempty input and simulated destination-write failure.




## VS-002 — P1 — External pairing deep link exports sensitive pairing data without consent and logs it



**Where:** `Vendor/SideStore/SideStore/DeepLinks/URLHandler.swift:78–85` routes `pairing` requests directly to `DeepLinks/ExportPairingFileHandler.swift:13–48`; the full encoded record is logged at line 39. `AltStore/SceneDelegate.swift:26,92` receives incoming URLs; the integration patch preserves this route.



**Why / trigger:** An external app can open `sidekick://pairing?urlname=<its-scheme>` (or the retained SideStore scheme). The handler immediately reads the active pairing record and opens the caller-controlled callback scheme containing its complete base64 value. No confirmation names the receiving app or explains the transfer, unlike certificate export. Base64 is reversible and the complete payload is additionally copied into diagnostic logs. This exposes device pairing credentials through a normal external entry point without an intentional export action and can expose them again when users share logs.



**Suggested fix:** Validate the receiving scheme, require an explicit export confirmation naming the destination and explaining access granted, and never log pairing contents or a callback URL containing them. Prefer a controlled share/document flow; retain callback support only with validated destinations and explicit consent. Test cancellation and assert diagnostic output contains no record payload.




## VS-003 — P2 — Pipeline reports success when installation metadata could not be saved



**Where:** `Vendor/SideStore/SideStore/Core/Operations/PipelineRunner.swift:248–267`, `performOperation`.



**Why / trigger:** The pipeline completes installation/refresh, attempts `dbContext.save()`, catches and logs any persistence error, then unconditionally calls `group.set(.success(result))` and logs SUCCESS. A disk-full or persistent-store failure leaves the app's refreshed expiration/certificate/cache identity absent from durable storage, while the UI and completion callers receive success. After restart users can see stale status or an installed app missing from management, with no repair prompt explaining that the device operation succeeded but tracking failed.



**Suggested fix:** Propagate a distinct persistence failure with the completed device result and offer metadata reconciliation; do not return an unqualified success. Keep the post-install state available for recovery rather than rolling back the device action. Test a successful device operation followed by a failing managed-context save.







## VS-004 — P2 — Batch cellular refresh leaves mobile data off on injection failure



**Where:** `Vendor/SideStore/SideStore/Core/Operations/StandaloneOperations/InjectBatchProfilesOperation.swift:43–67`; called by `Core/Operations/PipelineRunner.swift:209–222`.



**Why / trigger:** The batch operation runs the TurnOffData shortcut, then throws on any profile installation or managed-context save failure. TurnOnData is only called after the complete loop succeeds. The enclosing runner's defer clears progress/background state but does not restore data. This differs from the single-app `RefreshAppOperation`, which restores data in both its success and catch paths. With two or more cellular refreshes, a failed install can therefore leave the user's mobile data disabled after the reported failure.



**Suggested fix:** Guarantee restoration on every exit, including cancellation, using an explicit async cleanup success/catch pattern that runs after the attempted toggle. Test failure during the first profile and during record saving, and verify exactly one restoration attempt.



## VS-005 — P2 — Batch refresh never updates app or extension provisioning expiration



**Where:** `Vendor/SideStore/SideStore/Core/Operations/PipelineOperations/RefreshAppOperation.swift:34–47` queues the batch and returns before `updateInstalledApp`; `StandaloneOperations/InjectBatchProfilesOperation.swift:51–60` updates only certificate status.



**Why / trigger:** Single refresh calls `installedApp.update(provisioningProfile:)` and updates every extension after profile installation. The cellular multi-app path queues raw profile bytes, returns the existing app, and later injects them without applying profile creation/expiration metadata to either app or extensions. A successful batch therefore leaves stale expiry dates in the database and UI, so users can be told apps are expiring even after successful refresh, and subsequent expiration-based refresh scheduling uses stale state.



**Suggested fix:** Carry parsed profile identity/metadata with each pending batch and update the main app and each extension only after their profiles are installed successfully. Reuse the same post-install state update routine as a single refresh. Verify batch and single refresh produce identical persisted dates for a main app with extensions.




## VS-006 — P1 — Every installed third-party app receives the account's private signing key



**Where:** `Vendor/SideStore/SideStore/Core/Operations/PipelineOperations/EmbedSigningCertOperation.swift:38–44`; `Core/Certificates/CertificateManager.swift:49–55,81–86`; invoked unconditionally by normal install/resign step lists in `Core/Operations/OperationStepDefinition.swift:51,74`.



**Why / trigger:** The operation converts the active/override signing certificate to PKCS#12 and writes `ALTCertificate.p12` inside the target app bundle, including ordinary third-party apps. The export password is the certificate serial number (`getPassword`), which is public and retrievable from that same app's code signature or PKCS#12 certificate. Any installed app can therefore read its own bundle and recover the signing private key. Signing an app requires producing a signature, not giving the signed app the signing credential. Sharing/exporting the resigned IPA also distributes this recoverable key. The current integration patch does not restrict this step.



**Suggested fix:** Embed only public DER certificate material in third-party apps. If self-reinstallation needs private signing credentials, restrict PKCS#12 embedding explicitly to the authenticated store app and avoid a password derived from public certificate data; preferably retain private keys only in the manager's Keychain. Check existing exported IPAs and consider certificate rotation for exposed credentials. Validate that a third-party signed bundle contains no private key.




## VS-007 — P1 — Untrusted IPA dependency path can escape its app bundle and overwrite manager data



**Where:** `Vendor/SideStore/SideStore/Core/Operations/StandaloneOperations/DownloadAppOperation.swift:240–280` (`downloadDependencies` and dependency download destination).



**Why / trigger:** An imported app's `AltStore.plist` supplies `ALTDependencies[].path`; the manager downloads its `downloadURL`, appends the raw path to the extracted app bundle, creates parent directories and copies with replacement. No normalization, traversal check, or symlink containment check constrains the destination to the staged app. A crafted dependency path containing `../` components can reach sibling staging or other writable manager-container files. This gives an uninstalled IPA a write primitive in the manager's sandbox before app verification/signing completes. A malicious dependency can replace unrelated app data or configuration rather than merely populate its bundle.



**Suggested fix:** Resolve and normalize the destination against a canonical staged bundle root, reject absolute/traversing paths and symlink escapes, enforce allowed download URL schemes, and copy only after containment is verified. Test `../`, nested traversal, absolute paths and symlink parents against a sibling sentinel file.



## VS-008 — P2 — Compatible-version fallback still downloads the original version URL



**Where:** `Vendor/SideStore/SideStore/Core/Operations/StandaloneOperations/DownloadAppOperation.swift:35,89–120,130–143`.



**Why / trigger:** The initializer stores `sourceURL = app.url`. When the latest source version fails the OS compatibility check, the user can accept a compatible older version and the code calls `download(latestSupportedVersion)`. That method sets `context.appVersion` to the older version but fetches the initializer's original `self.sourceURL`, not the passed version's URL. The user agrees to an older supported build yet receives the newest incompatible IPA, while metadata claims it is the supported version. Later verification may reject it or the wrong version may be installed if its declared deployment metadata differs.



**Suggested fix:** Derive the download URL from the actual selected `app`/`AppVersion` argument at download time. Keep the downloaded URL, release track and version metadata tied to the same selection; test latest and compatible builds with distinct URLs and bytes.







## VS-009 — P2 — Pairing replacement deletes the working record before the new write succeeds



**Where:** `Vendor/SideStore/SideStore/Core/Pairing/PairingFileManager.swift:115–127`, `savePairingFile`; called by `importPairingFile` and the first-party pairing setup importer.



**Why / trigger:** Once the input parses, the manager deletes the existing protocol's pairing file with `try? removeItem`, then writes the replacement atomically. If that write fails (for example disk-full), the caller receives an error but the previously working pairing record has already disappeared. Atomic writes are designed to replace the destination safely; deleting it first defeats that protection. Failed imports can therefore break existing app refresh rather than leave setup unchanged.



**Suggested fix:** Remove the preliminary deletion and rely on atomic replacement; preserve the existing file on any write failure. Test importing into an existing working record with the write forced to fail and verify the original bytes and selected protocol remain usable.




## VS-010 — P2 — Self-app group filtering mutates the array using stale enumeration indices



**Where:** `Vendor/SideStore/SideStore/Core/Operations/PipelineOperations/FetchProvisioningProfilesOperation.swift:328–331`, `updateAppGroups`.



**Why / trigger:** For a store app, the method enumerates `applicationGroups` and removes entries at the enumeration's original indices whenever they contain `AltStore`. Removing an earlier element shifts subsequent elements. With two matching groups, a later removal can target the wrong group or exceed the current array count and crash. This can occur when refreshing a store IPA with multiple legacy groups or custom entitlements; signing setup should report unsupported groups rather than terminate the app.



**Suggested fix:** Filter in one operation (`removeAll(where:)`) or build a retained list instead of deleting by the original enumerated index. Check zero, one and multiple legacy groups interleaved with required groups.







## VS-011 — P2 — Short successful OCSP responses crash the app instead of returning a validation error



**Where:** `Vendor/SideStore/SideStore/Core/Certificates/OCSPValidator.swift:332–354`, `parseOCSPResponse`.



**Why / trigger:** The parser accepts any response longer than five bytes beginning with a sequence and successful response-status tag. If no valid-status byte pattern is found, it constructs `0..<(bytes.count - 20)` without requiring at least twenty bytes. A six-to-nineteen-byte response such as a DER response-status-only sequence therefore forms a range with upper bound below zero, which traps. The preceding `bytes[offset]` accesses also trust the encoded header length without validating it. These bytes come from a network OCSP response; malformed or truncated successful HTTP responses should be rejected, not terminate a refresh and the app.



**Suggested fix:** Use a bounded DER parser, check lengths before every indexed field/range, and return a structured invalid-response status for missing response bytes. Test responses of lengths 0–20 and oversized ASN.1 length headers.



## VS-012 — P1 — OCSP certificate state trusts unauthenticated byte patterns in an HTTP response



**Where:** `Vendor/SideStore/SideStore/Core/Certificates/OCSPValidator.swift:186–206,332–357`; `PipelineOperations/VerifyCertificateOperation.swift:124–145` turns this status into stored certificate validity/revocation.



**Why / trigger:** Direct live OCSP uses HTTP, then scans arbitrary response bytes for generic status patterns. It never verifies the BasicOCSPResponse signature/responder authority, requested certificate serial/issuer hash, or freshness timestamps. A proxy or modified HTTP response can therefore supply a valid/revoked-looking byte pattern for any requested certificate. A signed OCSP protocol can safely operate over HTTP only when its signed payload and identity are validated; this implementation provides neither check, while `.revoked` blocks operations and generic `.valid` marks the certificate usable.



**Suggested fix:** Use Security framework trust/revocation evaluation as the authority or a complete OCSP verifier checking signer authority, CertID and thisUpdate/nextUpdate. Treat uncertain network results as unknown rather than authoritative valid or revoked. Test a wrong-serial response, an invalid signature and an expired signed response.




## VS-013 — P2 — SideJIT URL resolution silently drops HTTPS and custom URL paths



**Where:** `Vendor/SideStore/SideStore/Core/JIT/SideJITManager.swift:43–105`, `resolveAddressIfNeeded`.



**Why / trigger:** A configured server URL is parsed, but every direct-IP, hostname and DNS fallback reconstructs only `http://host:port`. The original scheme, path and other URL components are discarded, with port 8080 even for an HTTPS URL without an explicit port. A user entering `https://jit.example/server` is therefore sent to `http://jit.example:8080` instead. HTTPS-only and reverse-proxy configurations fail, and an explicit transport choice is downgraded while device UDID and bundle identifiers are later sent to that server.



**Suggested fix:** Preserve URLComponents scheme, explicit/default port and base path while replacing only the resolved host; bracket IPv6 addresses correctly and preserve necessary interface scopes. Add deterministic checks for HTTPS with omitted port, a prefixed base path, IPv4 and IPv6.




## VS-014 — P2 — Embedded certificate fallback returns a certificate with the wrong serial



**Where:** `Vendor/SideStore/SideStore/Core/Certificates/CertificateManager.swift:273–307` (`loadEmbeddedCertificate`); consumed by `Core/Profiles/ProfileManager.swift:119–146,163–191`.



**Why / trigger:** Every successful decrypt assigns `signableCert`, even when its serial does not match the requested serial. After trying the passwords, the method returns that mismatching certificate whenever any decrypt succeeded. The profile manager treats a non-nil fallback as a matching private key and reports the profile ready to sign. A profile for certificate B can therefore be labeled signable and paired with the embedded private key for certificate A, leading to signing or installation failure and misleading certificate setup status.



**Suggested fix:** Return a certificate only if its normalized serial (or exact certificate data) matches the requested identity; only an explicitly empty identity may request the default embedded certificate. Test a decryptable embedded certificate whose serial differs from the requested profile certificate.




## VS-015 — P1 (retained tvOS code; excluded from current iOS build) — Web upload trusts filename paths and can overwrite files outside tmp



**Where:** `Vendor/SideStore/SideStore/Core/tvOS/TVWebFileTransferManager.swift:278–314`, `processUploadedBody`.



**Why / trigger:** Multipart `filename` is accepted verbatim, appended to the manager temporary directory and written with replacement semantics. The LAN server has no session token or peer authentication. A crafted HTTP upload with `filename="../Library/..."` can escape tmp and overwrite a writable manager-container file. Accepted extensions are only placed in the HTML input's `accept` hint; the server does not enforce them. This is a real defect in the retained tvOS implementation, but `#if os(tvOS)` excludes it from SideKick's current iOS build.



**Suggested fix:** Reduce filenames to a sanitized basename, use a unique per-transfer directory, verify canonical containment, enforce server-side file types and upload size, and require a short-lived transfer token. Test traversal filenames and unsupported extensions. Keep this finding separated from active iOS release blockers.




## VS-016 — P2 — Markdown mutations mix character and UTF-16 lengths, corrupting emoji links



**Where:** `Vendor/SideStore/SideStore/Extensions/NSAttributedString+Markdown.swift:191–204,509–516`, inline-link replacement and paragraph serialization.



**Why / trigger:** The parser scans NSString ranges in UTF-16 units, then updates `mutationOffset` using `replacementString.count` (Swift grapheme count). A link label such as an emoji occupies two or more UTF-16 units but one Swift Character. After replacing `[😀](https://example.com)`, subsequent marker positions are calculated too far left and can delete part of the emoji or target an invalid range. Paragraph export likewise uses `component.count` for NSRange location/length. This affects any caller supplying markdown with emoji or combining characters; a retained upstream App IDs header calls this renderer. Current SideKick home-screen reachability is not established for this renderer.



**Suggested fix:** Use NSString length or `utf16.count` consistently for all NSRange offsets, or maintain native String.Index positions throughout. Test emoji and combining-mark link labels followed by emphasis and multiple paragraphs; verify both rendering and round-trip serialization preserve text.







## VS-017 — P2 — Cancel on the app-group correction dialog continues the installation



**Where:** `Vendor/SideStore/SideStore/Handlers/PipelineHandler.swift:471–475`, `resolveAppGroupMismatch`; `PipelineOperations/FetchProvisioningProfilesOperation.swift:435–445` consumes the result.



**Why / trigger:** The correction dialog offers Correct & Proceed, Keep Original and Cancel. Both Keep Original and Cancel resume with `.keepOriginal(originalGroup)`. The caller then continues group registration/signing; no cancellation error is thrown. A user who backs out of an identifier discrepancy can therefore still trigger the install using a group they declined to resolve. Other customization dialogs correctly map Cancel to `OperationError.cancelled`, making this inconsistent and unsafe for user intent.



**Suggested fix:** Resume the throwing continuation with `OperationError.cancelled` for Cancel, or introduce an explicit cancellation case and propagate it. Verify no portal mutation or signing step occurs after cancellation.




## VS-018 — P1 — Payload cache identity hashes filenames and sizes, not file contents



**Where:** `Vendor/SideStore/SideStore/Utils/common/AppBundleFingerprint.swift:34–37`; reused by `Core/Operations/PipelineOperations/CacheAppOperation.swift:38–52` and maintenance migration.



**Why / trigger:** Each leaf hash covers only `name|size`, so two bundles with identical directory layout and file lengths but different executable/resource bytes have exactly the same fingerprint. `CacheAppOperation` treats a matching fingerprint directory as an already cached payload and skips copying. A newly verified update can install correctly on that attempt yet its database fingerprint points to the older cached executable; later resign/reinstall/backup operations stage the old payload. Equal-sized metadata changes are also lost, and different apps with the same layout/sizes can share incorrect cached code. A cryptographic outer hash does not fix missing content in its inputs.



**Suggested fix:** Hash file bytes as well as relative paths using streaming reads; define intentional exclusions explicitly and fail rather than omit unreadable children. Version or migrate the cache identity so existing metadata-only fingerprints cannot alias the new format. Verify that a one-byte equal-length change produces a different key and that re-sign stages the updated executable.




## VS-019 — P2 — Invalid certificate in an account backup clears the existing working account first



**Where:** `Vendor/SideStore/SideStore/Utils/importexport/ImportExport.swift:114–136`, `importAccount`; debug JSON import repeats the ordering at lines 281–294.



**Why / trigger:** After decryption/JSON decode succeeds, the importer immediately signs out (clearing active certificate and sign-in state), writes incoming email/password/anisette fields, and only then parses/imports the backup's certificate. A malformed certificate, bad certificate password or certificate persistence failure throws after the previous account was erased. The broad catch also labels such failures as an incorrect password/corrupt backup, obscuring that state was partially replaced. Users trying an invalid backup can lose a previously working setup instead of getting a harmless validation error.



**Suggested fix:** Fully validate backup version, account fields and certificate/private key before mutating any existing state; then apply as a transaction with rollback or a staged credential set. Preserve underlying error distinctions and test a decryptable backup with invalid certificate data against an existing signed-in account.




## VS-020 — P2 — Console capture crashes when its log file cannot be created



**Where:** `Vendor/SideStore/SideStore/Utils/iostreams/ConsoleLog.swift:50,136–138`, lazy `consoleLogger` and log-directory creation.



**Why / trigger:** Log capture force-unwraps `createLogFileHandle()` and log directory creation uses `try!`. If Documents/ConsoleLogs creation or file open fails (for example low storage or a conflicting file at that directory path), launching capture terminates the app. Logging is auxiliary functionality and should never prevent boot or recovery from the storage error it needs to describe.



**Suggested fix:** Make capture initialization failable and fall back to system/original console output when the file destination is unavailable. Return an actionable diagnostic state without crashing; test directory creation and FileHandle-open failure.




## VS-021 — P2 — Entitlement customization silently drops values it cannot represent



**Where:** `Vendor/SideStore/SideStore/Views/Components/EntitlementsCustomizationViewModel.swift:90–110,327–367`; active customization route `Core/Operations/PipelineOperations/UserCustomizationOperation.swift:149–203` and `Handlers/PipelineHandler.swift:308–319`.



**Why / trigger:** The editor only parses Boolean, string, string-array and NSNumber entries. Dictionary, Data and arrays of other plist values disappear from the editor. Proceed reconstructs the entire dictionary from those entries, preserving only the two identity keys from the original. Thus opening customization and proceeding without changes drops other original entitlements even on paid teams, where `isEntitlementAllowed` permits them. The returned replacement is persisted into the signing context, so this is destructive normalization of signing configuration rather than merely a hidden row.



**Suggested fix:** Preserve untouched values of every supported plist type, using a read-only/raw editor for types the form cannot edit. Show any policy-driven removals before proceeding. Verify a round trip containing nested dictionary/Data/heterogeneous-array values retains them when no changes were requested.



## VS-022 — P3 — Array entitlement editors share a single draft input across rows and targets



**Where:** `Vendor/SideStore/SideStore/Views/Components/EntitlementsCustomizationCoreView.swift:511–525`; `EntitlementsCustomizationViewModel.swift:78,113–135,248–254`.



**Why / trigger:** Every array row binds its Add item field to the same `newArrayItemText`. Typing a group ID in the application-groups row makes it appear in every other array row and enables all their Add buttons. Pressing another row's button adds that group ID to the wrong entitlement and clears every row's draft. Target switching also keeps this draft, making an app draft appear on an extension. These are independently labeled inputs and their state should be independent; incorrect keychain/application-group values can then reach signing.



**Suggested fix:** Store draft text by target and entry ID, or keep it in each row's state. Clear only the draft committed by that row, and preserve or explicitly discard drafts on target changes. Verify two array rows can hold distinct pending values.




## VS-023 — P2 — Deleting a raw Info.plist key leaves it in the generated app



**Where:** `Vendor/SideStore/SideStore/Views/Components/InfoPlistCustomizationCoreView.swift:831–833,964–1030`, raw-key trash action and `serialize`; reached through the install customization handler.



**Why / trigger:** Trash removes the entry from `rawEntries`, so the form visibly confirms the key is gone. Serialization starts with the entire original plist and only overwrites remaining entries; it never removes keys deleted from the draft. For any original raw key, proceeding restores its original value in the returned plist. For example removing a usage-description/custom configuration key does not alter the installed app. This makes the editor's delete action unreliable and makes a subsequent audit of requested metadata edits misleading.



**Suggested fix:** Track deleted original keys per target and remove them from the original before applying remaining entries, or reconstruct editable scalar keys while preserving only the unsupported complex values. Verify deleting, editing and adding a key together produces exactly those changes for both main app and extension.







## VS-024 — P2 — Clear Private Key reports success while an active key remains available



**Where:** `Vendor/SideStore/SideStore/Views/Settings/Advanced/Certificates/CertificatesViewModel.swift:657–662`, `clearPrivateKey`; `Core/Certificates/CertificateManager.swift:159–166,185–187,260–266`.



**Why / trigger:** Clear Private Key overwrites the imported certificate slot with public DER and announces that the locally stored private key was removed. It leaves `CertificateManager.activeCertificate` and its separate active signing-key storage intact. `getLocalCertificate` returns this active private key before reading the overwritten slot, so the refreshed screen still reports a private key and signing can continue using it. The UI does not disallow clearing the active certificate, and embedded-certificate fallback can also make cleared keys available again. A user requesting key removal cannot rely on the success message.



**Suggested fix:** Define the clear action's scope explicitly. When clearing the active certificate, remove/deactivate the active signing copy too; account for any embedded fallback and explain if it cannot be erased from the installed bundle. Verify the post-action key lookup and signing state before reporting success.







## VS-025 — P2 — App ID group editor treats every team group as an existing association



**Where:** `Vendor/SideStore/SideStore/Views/Settings/Advanced/DeveloperServices/AppIDs/AppIDDetailView.swift:181–191`, `initializeSelectedGroups`, with Save Group Associations at lines 121–134.



**Why / trigger:** Initialization checks only whether the App Groups capability key exists, then selects every group in `viewModel.appGroups`. A capability flag does not identify which groups belong to this App ID, and the feature value is not even checked. For a team containing groups A/B/C where the app belongs only to A, the UI falsely marks A/B/C associated. Toggling one row and saving submits all remaining team groups, unintentionally broadening/changing associations. This retained developer-portal UI must obtain the actual association list before exposing a destructive replacement save.



**Suggested fix:** Fetch the groups associated with this App ID and initialize selections from that list. Keep association editing disabled while loading or on fetch failure. Verify an app associated only with A displays only A selected, and adding B submits A/B without unrelated C.




## VS-026 — P2 — Editing a portal profile replaces its certificate set with all team certificates



**Where:** `Vendor/SideStore/SideStore/Views/Settings/Advanced/DeveloperServices/Profiles/ProfilePortalDetailView.swift:316–318,221–231`.



**Why / trigger:** On appearance, the editor initializes selected certificates from every team certificate rather than the certificates currently authorized by this profile. Saving even a simple name change regenerates the profile with that invented set. A profile intentionally limited to one signing certificate is thus broadened to unrelated certificates or rejected for incompatible certificate types. The Associated Certificates heading presents these defaults as actual existing associations.



**Suggested fix:** Download/query this profile's existing certificate associations and map exact portal IDs to the selection. Keep loading/error state separate from an empty association. Verify a name-only edit preserves the profile's original certificate and device sets.



## VS-027 — P2 — Portal profile editor cannot save certificate-only edits or device-free profiles



**Where:** `Vendor/SideStore/SideStore/Views/Settings/Advanced/DeveloperServices/Profiles/ProfilePortalDetailView.swift:30–46,218–249`.



**Why / trigger:** `hasChanges` compares only name, app ID and devices, so changing certificate selections alone never displays Save Changes. Separately `canSave` always requires a device selection, including profile types whose `acceptedDeviceTypes` are none (the create-profile form correctly supports that case). A user replacing a certificate must make an unrelated edit to reveal Save, and editing a device-free distribution profile is blocked unless unrelated device IDs are supplied.



**Suggested fix:** Compare certificate selections against the true original certificate set when computing changes, and derive the device requirement from `profile.profileType.acceptedDeviceTypes`. Verify certificate-only updates and name-only changes to a device-free profile can be submitted without unrelated modifications.




## VS-028 — P2 — A previous Bonjour resolution can populate and cancel a newer service's details



**Where:** `Vendor/SideStore/SideStore/Core/Bonjour/BonjourDiscoveryManager.swift:314–323,473–518,521–529`; details view consumes global result in `Views/Settings/Advanced/NetworkDiscovery/BonjourDiscoveryView.swift:711–719`.



**Why / trigger:** Finishing a resolution starts an untracked detached DNS task. Stopping/changing service cancels only connection, NetService and timeout, not this task. Its final guard checks only `isResolving` and an empty result. If the user opens service A then quickly switches to B while A's DNS work runs, B sets those same flags; A's late task passes, publishes A's addresses under B's detail screen, then stops B's live resolution. The result must be associated with the specific request identity.



**Suggested fix:** Assign a generation/request token to each resolve and check it in every callback and final publish. Cancel tracked DNS work where possible and reject stale results regardless. Verify delayed A resolution cannot replace B's result or stop B's request.



## VS-029 — P2 — Re-resolving the same Bonjour service cannot publish updated addresses



**Where:** `Vendor/SideStore/SideStore/Core/Bonjour/BonjourDiscoveryManager.swift:318–320,503–504`; `Views/Settings/Advanced/NetworkDiscovery/BonjourDiscoveryViewModel.swift:460–474,490–492`.



**Why / trigger:** The auto-refresh/manual path calls `resolveService` with `clearExisting` false. For the same service name, its previous `resolvedService` is retained, but `finishResolution` only publishes when that property is nil. Therefore an already resolved service never receives its newly resolved IP/port/TXT data, despite recurring refreshes and successful network callbacks. Two distinct services with the same name in different type/domain scopes also retain the wrong prior result because only name is compared.



**Suggested fix:** Keep the old display while refreshing, but allow the current request to replace it when it completes. Compare full service identity, not just name, and combine with generation validation for VS-028. Verify changing an advertised IP/TXT value appears after manual and periodic refresh.




## VS-030 — P2 — Server interface selection is displayed but never affects advertising



**Where:** `Vendor/SideStore/SideStore/Views/Settings/Advanced/PairingFile/WirelessPair/WirelessPairViewModel.swift:198–210,297–315,487–503`; `WirelessPairTargetDialog.swift:124`.



**Why / trigger:** The dialog lets the user choose an interface and the view model logs the selected ID on confirmation, but `startPairing()` does not receive or read that ID. It invokes `wirelessPairing.start` with only a documents path and filename resolver, so choosing Wi-Fi, VPN, or another interface has no effect on the listener. The UI suggests a network restriction that the underlying API does not implement; users may expose the pairing endpoint on all interfaces or select a network believing the endpoint is reachable there.



**Suggested fix:** Remove interface selection until the pairing API supports binding, or clearly label that advertising listens on all interfaces. If binding is supported, pass and enforce the selected address. Verify choosing each option changes the bound endpoint or that the UI explains the all-interface behavior.




## VS-031 — P3 — A denied security-scoped profile import fails silently



**Where:** `Vendor/SideStore/SideStore/Views/Settings/Advanced/Profiles/ProfileManagementView.swift:220–229`.



**Why / trigger:** When Files returns a profile URL but `startAccessingSecurityScopedResource()` returns false, the callback returns without a message. The importer closes and nothing explains why no profile appeared, while other parsing/import failures in the same flow produce a toast. The user cannot distinguish a permission failure from a successful no-op.



**Suggested fix:** Surface a concise access error and leave the profile list unchanged. Verify denied access produces visible feedback and successful access still releases the scope with `defer`.




## VS-032 — P2 — SideSign raw JSON view stays stale while interactive fields change



**Where:** `Vendor/SideStore/SideStore/Views/Settings/Advanced/UserCustomizations/SideSign/SideSignConfigurationView.swift:64–93,183–191,306–323`.



**Why / trigger:** `rawEditableJSON` is refreshed only during load, save, and reset. Editing any interactive field and switching to Raw JSON before saving shows the previous configuration, not the current draft. Saving that visible JSON can overwrite the form edits with stale values, and the segmented picker gives no indication that the two modes have diverged.



**Suggested fix:** Regenerate JSON when entering raw mode from interactive state, or keep one parsed draft as the source of truth and make unsaved changes explicit. Verify edits survive switching both directions and cannot be silently replaced by stale JSON.




## VS-033 — P2 — Portal lookup failures are presented as missing device registration



**Where:** `Vendor/SideStore/SideStore/Views/Settings/Auth/AccountVerificationRow.swift:175–193,196–228`.



**Why / trigger:** Any error fetching the team's portal devices falls through to `.actionRequired(...deviceUnregistered: true)`, exactly like a successful lookup proving the device absent. The row then tells users device registration is pending and offers a registration flow even when the real cause is network, authentication, or portal failure. Repeated transient failures can prompt unnecessary registration attempts and obscure the actionable error.



**Suggested fix:** Model verification failure separately from a confirmed missing device, show retry/error feedback, and offer registration only after a successful lookup proves absence. Verify offline and portal-error responses never claim the device is unregistered.




## VS-034 — P2 — Export Database creates a file then discards the only URL



**Where:** `Vendor/SideStore/SideStore/Views/Settings/Diagnostics/DeveloperOptionsView.swift:228–245,812–830`.



**Why / trigger:** The Export Database action awaits `CoreDataHelper.exportCoreDataStore()` and logs the returned URL, then drops it. There is no document exporter, share sheet, or visible location feedback. The spinner ends and the user has no way to retrieve the database they asked to export; the utility may consume temporary storage without delivering an artifact.



**Suggested fix:** Present the exported URL through the platform's export/share flow and report errors to the user. Verify the exported file can be saved or shared on supported platforms.




## VS-035 — P2 — An empty search result hides the search field and traps the query



**Where:** `Vendor/SideStore/SideStore/Views/Settings/TechyThings/StorageExplorer/DirectoryExplorerView.swift:62–100`.



**Why / trigger:** The view switches from the list to an “Empty Directory” screen whenever `filteredAndSortedItems` is empty. The searchable modifier exists only on the List branch. If a nonempty folder search has zero matches, the search control disappears while `searchText` remains set; users see a message that the directory itself is empty and cannot clear the query from this screen.



**Suggested fix:** Keep the list/search container present for nonempty directories and show a dedicated “No matching items” empty state with a clear-search action. Verify zero-match searches remain editable and return the original rows when cleared.




## VS-036 — P2 — Failed conflict-resolution copies are silently dropped



**Where:** `Vendor/SideStore/SideStore/Views/Settings/TechyThings/StorageExplorer/StorageExplorerViewModel.swift:465–487`.



**Why / trigger:** After the user supplies a new name for a paste conflict, `copyItem` failures are only written to debug logs. The conflict is removed and the next item is shown, so the flow can appear successful even though the requested file was not copied. This is especially confusing for permission or storage failures because the original conflict dialog vanishes without a result.



**Suggested fix:** Keep the failed conflict active for retry or show an actionable error before advancing. Verify an injected copy failure is visible and does not lose the source item from the pending queue.




## VS-037 — P2 — Cached widget icons never refresh for an existing bundle ID



**Where:** `Vendor/SideStore/SideStore/Widget/WidgetData/WidgetDataManager.swift:88–99`.



**Why / trigger:** `cacheIcon` writes an icon only when `<bundleID>.png` does not already exist. Later publishes for the same app skip the new image indefinitely, so app icon changes and newly customized icons remain stale in widget/Top Shelf snapshots even though the data is republished.



**Suggested fix:** Replace the cached image atomically when the source icon changes, or compare a content/version key before skipping the write. Verify a second publish for the same bundle ID updates the rendered icon.




## VS-038 — P2 — Failed profile downloads are hidden while portal refresh reports success



**Where:** `Vendor/SideStore/SideStore/Views/Settings/Advanced/Profiles/ProfileManagementViewModel.swift:78–100`.



**Why / trigger:** A portal profile absent from local storage is downloaded and imported through nested `try?` calls. If either step fails, the loop continues and the refresh still sets `hasFetchedRemote = true`, clears loading, and reports no error. The management list only renders local profiles, so that portal profile silently disappears from the screen even though the refresh completed.



**Suggested fix:** Collect download/import failures and surface which profiles could not be cached, while retaining portal metadata so they can be retried. Verify a failed download is visible as an error or retryable entry rather than a successful empty refresh.


## Consolidated vendor findings — Shared code, minimuxer, helpers and CLI

Scope: Vendor/SideStore except AltStore, AltStore.xcodeproj, SideStore. Audit only. SideKick CI applies integration patches, builds the SideStore scheme, then removes AltWidget from both shipped IPAs. Widget issues below are retained-upstream issues, not shipped SideKick widget defects. Nested dependency sources are included in the coverage manifest. No production edits or external actions.

## VP-001 — P2 — Substring self-app identity clashes with distinct app IDs

Where: `Vendor/SideStore/Shared/Extensions/Bundle+AltStore.swift:112-115`; callers include `Vendor/SideStore/SideStore/Core/Operations/PipelineOperations/UninstallAppOperation.swift:28` and `Vendor/SideStore/SideStore/Core/Operations/PipelineOperations/CacheSigningCertOperation.swift:28`.

Why/what: `contains(activeID)` and `contains(altstoreID)` treat any identifier containing the store ID as the store itself. For example, `com.sidekick.app.helper` is classified as SideKick when the active bundle is `com.sidekick.app`. The integration patch changes the identity constant but leaves this predicate intact. This makes distinct apps enter self-app protections/signing/cache paths; uninstall refuses apps misclassified as self. This is a concrete identity clash rather than merely legacy naming.

Fix suggestion: Define one canonical self-identity predicate that compares the exact original ID and exact resigned ID (with a validated team suffix where appropriate), and use it across pipeline, certificate, and UI code. Do not accept arbitrary prefixes/suffixes or substring matches. Verify a helper ID containing SideKick's ID remains an ordinary app while the actual resigned SideKick remains protected.

## VP-002 — P2 — Top controller lookup skips a modal presented by the navigation/tab container

Where: `Vendor/SideStore/Shared/Extensions/UIApplication+AppExtension.swift:28-38`.

Why/what: The helper descends into UINavigationController/UITabBarController before checking `presentedViewController`. When a modal is presented by the container, it returns the underlying visible/selected child instead of the modal. Callers then try to present another flow from an offscreen controller, causing warnings or missing prompts. A nil selected child also restarts the lookup at the root because nil means default, creating recursion when a tab container has no selected controller.

Fix suggestion: Resolve the root once, check its presented controller first, then descend into non-nil navigation/tab children. Return the container when no child is available. Verify container-presented modal and empty-tab cases.


## VP-003 — P2 (retained upstream widget) — Pagination can force unwrap a missing state holder

Where: `Vendor/SideStore/AltWidget/Intents/PaginationIntent.swift:60-66`, `Vendor/SideStore/AltWidget/Providers/ActiveAppsTimelineProvider.swift:54-58`, `Vendor/SideStore/AltWidget/Manager/PageInfoManager.swift:14-15`.

Why/what: Page state exists only in process memory. After an extension restart, a pagination intent reads no previous event and stores a new event with a direction but nil `dataHolder`. The next provider update enters the direction branch and force unwraps that nil holder, crashing instead of changing page. A new dispatch queue for each intent does not persist or serialize shared page state; parallel instances can also mutate the dictionary concurrently.

Fix suggestion: Persist only a stable page index per widget in the shared container and update it through a single serialized state owner. At minimum, initialize a fresh holder whenever the saved holder is nil and avoid force unwraps. Exercise pagination immediately after extension termination and two widgets navigating concurrently. SideKick's packaging currently removes this extension, so this affects retained upstream widget builds.


## VP-004 — P3 (retained upstream widget) — Per-app countdown action refreshes every app

Where: `Vendor/SideStore/AltWidget/Widgets/ActiveAppsWidget.swift:175-185`, `Vendor/SideStore/AltWidget/Extensions/View+AltWidget.swift:43-50`, `Vendor/SideStore/AltWidget/Widgets/AppDetailWidget.swift:35-36`.

Why/what: A countdown visually belongs to one app, and descriptions say tap the countdown to refresh it/them. Every countdown is wrapped in `RefreshAllAppsWidgetIntent`, so selecting one app's timer starts a global refresh. This is surprising when other apps require input, fail signing, or consume refresh time.

Fix suggestion: Either expose a refresh-app intent carrying that app's canonical ID, or label the timer/action explicitly as Refresh All Apps and move it to a global control. Keep descriptions and accessibility labels aligned with the real scope. This remains dormant in the shipped SideKick IPAs because widgets are removed.


## VP-005 — P2 — First backup assumes an existing destination to replace

Where: `Vendor/SideStore/SideBackup/BackupEngine.swift:178-184,242-243,284-285`.

Why/what: Backup creates a unique temporary directory and copies the data successfully, then always calls `replaceItemAt(appBackupDirectory, ...)`. There is no branch to move the temporary backup into place when no prior backup exists. Foundation's replacement operation requires an original item; a new app's first backup can fail at the final step and the catch removes the newly copied temporary backup.

Fix suggestion: If the destination exists, replace it atomically; if absent, move the staged directory into the final destination. Keep both cases within the coordinated intent and only delete staging on true failure. Verify first backup, replacement backup, and simulated copy failure preserving the prior backup. This target remains upstream helper code; establish its packaging/re-signing use before prioritizing for SideKick.


## VP-006 — P1 — Copy retries can silently report success after copying nothing

Where: `Vendor/SideStore/SideBackup/BackupEngine.swift:456-479`, callers at `399-406`, final completion at `285-286,327`.

Why/what: For repeated file-exists errors, `copyItemRetrying` removes the conflicting destination and loops, but falls out of the retry loop without throwing or verifying a copy. On the final attempt, removal may even succeed and leave the destination absent; the caller still increments copied bytes and success count. Locking errors are also skipped by the caller regardless of `skipNonCopyable`, then the new backup replaces the prior backup and completion reaches 100%. Restore can therefore omit user data while being announced successful.

Fix suggestion: Track actual copy success, throw the last error on exhaustion, and return an explicit copied/skipped outcome for intentional skip mode. Make strict backup/restore abort on skipped items; partial backups must be identified and must not silently replace the last complete backup. Verify persistent file-exists/locking errors and final-attempt deletion outcomes.


## VP-007 — P2 — Overlapping backup requests overwrite the return context

Where: `Vendor/SideStore/SideBackup/SideBackupApp.swift:58-66,74-88,191-209,236-276`.

Why/what: Each incoming backup/restore URL replaces the single `currentBackupReturnURL` and starts a task with no busy guard. A second request while the first is copying replaces the first callback, may launch restore concurrently, and the first completion clears the callback needed by the second operation. The caller can wait indefinitely and restore/backup can operate on changing data. Backgrounding also clears only UI state at 213-219 while work continues, allowing an inactive screen during active copying.

Fix suggestion: Serialize whole backup/restore operations and bind each operation to an immutable request ID and return URL. Reject or queue a second request explicitly. Retain a durable operation state through background transitions and clear it on completion, then deliver exactly one result for each accepted request.

## VP-008 — P2 — Failure callback discards the requested target bundle ID

Where: `Vendor/SideStore/SideBackup/SideBackupApp.swift:101-105,124-134`.

Why/what: The failure branch replaces the return URL's complete query list with error fields. The subsequent target-app resolution reads `targetBundleID` from that now-replaced list, so failure callbacks lose a supplied target ID and fall back to inferred IDs. Success retains the query. This makes the route back to the caller differ precisely on errors when reliable recovery is needed.

Fix suggestion: Resolve and retain the target bundle ID from the original request before editing the callback, or merge error fields into existing query items. Verify success/failure both launch the same explicitly selected caller.

## VP-009 — P2 — Recoverable operation error permanently becomes a boot failure

Where: `Vendor/SideStore/SideBackup/SideBackupApp.swift:236-241,262-267,288-291`; `SideBackup/ContentView.swift:20-35`.

Why/what: Every backup/restore failure is assigned to `bootCheckError`. Both future operations short-circuit on this property, and the screen says SideBackup could not start. A transient copy error therefore prevents retry until the process restarts and presents an inaccurate startup error. The `errorTitle` argument is unused.

Fix suggestion: Keep immutable startup entitlement/container failures separate from operation failures, reset operation status on completion, display the correct operation-specific error, and allow a retry after a recoverable failure.


## VP-010 — P3 — Contribution setup still requires removed dependency tooling

Where: `Vendor/SideStore/CONTRIBUTING.md:44-59,70-73` versus `Vendor/SideStore/AGENTS.md:17-20,58` and `.gitmodules:3-10`.

Why/what: CONTRIBUTING instructs contributors to run CocoaPods and `SideStore/fetch-prebuilt.sh`, says minimuxer is built from Rust, and warns about Cargo paths. The checked-out project uses Swift packages/pure Swift minimuxer, has no tracked Podfile or fetch-prebuilt.sh, and AGENTS describes the newer setup. Following the older contributor flow hits missing-file/setup failures and adds unnecessary tools.

Fix suggestion: Replace obsolete setup sections with the actual recursive-submodule/SPM workflow and minimum Xcode requirements; link SideKick contributors to the root patch/build workflow so they understand vendored versus integrated builds. Keep only documentation that matches commands present in the tree.

## VP-011 — P3 — Signing sample contains unrelated project identifiers and missing instructions

Where: `Vendor/SideStore/CodeSigning.xcconfig.sample:14-18,38-53`.

Why/what: The copy-and-customize signing sample tells users to register Provenance IDs, describes UTM hypervisor provisioning, and references nonexistent Documentation/MacDevelopment.md and Provenance/macOS.entitlements. This clashes with the actual SideStore iOS/tvOS targets and misdirects new contributors during signing setup.

Fix suggestion: Remove unrelated macOS/UTM/Provenance sections and document the actual SideStore main/helper/widget identifiers generated by Build.xcconfig. Provide separate free/paid examples that agree with DEVELOPER_ACCOUNT_PAID and chosen entitlements.


## VP-012 — P3 — Legacy QA/setup targets reference absent tooling

Where: `Vendor/SideStore/Makefile:78-81,112-124,145-155`.

Why/what: `pull_request` invokes Fastlane, Danger and the retired Codecov curl script; bundler setup is for version 1.17. No tracked Gemfile, Fastfile, Dangerfile, or supporting configuration exists in this checkout. These targets sit alongside functional xcodebuild test targets, creating two competing development workflows; selecting the older advertised targets fails rather than validating the code.

Fix suggestion: Remove unused legacy Ruby QA targets and unused RUBY/BUNDLER checks, or restore explicit maintained configuration if the project still needs them. Point help/development instructions at the working Swift/Xcode test path. Root SideKick CI uses its own direct build and does not run these legacy targets.


## VP-013 — P2 (upstream CI path) — Test/package pipelines hide failed commands

Where: `Vendor/SideStore/scripts/ci/workflow.py:149-150,157-162,204-211`.

Why/what: Only the main build pipeline requests pipefail. Test build, test run, fakesign and IPA commands pipe output to tee/xcbeautify without it. Shell success is the last pipeline command's status, so a failed xcodebuild/make step can be treated as successful and CI continues to archive results or publish artifacts. These vendor workflows are dormant inside SideKick's submodule; root CI runs its own tests/build with stricter failure handling.

Fix suggestion: Invoke subprocess pipelines through an explicit Bash shell with pipefail for every pipeline, or run commands directly and capture output without a shell pipeline. Verify deliberately failing test, signing and packaging commands make their wrapper and CI step fail.


## VP-014 — P2 — Readiness hardcodes Wi-Fi even for remote/wired connections

Where: `Vendor/SideStore/Dependencies/minimuxer/Sources/MinimuxerImpl.swift:117-125,128-152`.

Why/what: The shared readiness gate rejects every path unless `network.isWifiSatisfied`; wired/USB/bridge alternatives are commented out. This happens before checking localVPN versus remoteServer. A reachable remote endpoint over Ethernet or an external VPN/cellular route is therefore reported as No wifi interface satisfied even when the selected connection mode and endpoint work. It clashes with the public remote-server connection option and published network capability flags.

Fix suggestion: Apply prerequisites by connection mode and actual route requirements. Keep any necessary on-device local VPN restrictions explicit; for remoteServer validate endpoint reachability on its available path rather than requiring Wi-Fi globally. Verify working remote endpoint over wired and external-VPN routes, plus Wi-Fi disconnection handling.


## VP-015 — P2 — Dead heartbeat service remains wired into the composition root

Where: `Vendor/SideStore/Dependencies/minimuxer/Sources/MinimuxerApi.swift:270,282`, `Vendor/SideStore/Dependencies/minimuxer/Sources/MinimuxerImpl.swift:36,51,61`, `Sources/Services/HeartbeatService.swift:58-82`.

Why/what: The composition root creates and retains HeartbeatService, but no production call to heartbeat.start/stop exists anywhere in the dependency. Its lifecycle/status fields never participate in readiness, and the implementation never starts a keepalive. This is dead service wiring that suggests a capability the library does not activate; it also leaves an unchecked stop-insensitive waiting loop for any future reuse.

Fix suggestion: Establish whether gateway.performHeartbeat is intentionally unused. If redundant with backend connection keepalive, remove the service and injected references; if required, integrate explicit start/stop ownership after gateway startup and stop-sensitive waiting. Avoid retaining a nonfunctional lifecycle service.

## VP-016 — P1 — IPv6 sockaddr is truncated before passing its original length to getnameinfo

Where: `Vendor/SideStore/Dependencies/minimuxer/Sources/Services/NetworkIfaceScanner.swift:31-35,285-298,640-649`.

Why/what: IPv6 addresses are copied using `.pointee` from `UnsafePointer<sockaddr>`, which yields a 16-byte sockaddr value. `sockaddrIPv6` then passes `sa.sa_len` (normally 28 for sockaddr_in6) with the address of that 16-byte local value to getnameinfo. It reads beyond the copied value instead of the full IPv6 address. Scanning IPv6 interfaces/routes can therefore return corrupt addresses or access adjacent stack memory. This is in the live network discovery dependency, not just diagnostic code.

Fix suggestion: Preserve the original pointer and its validated length, then rebound/read sockaddr_in6 for AF_INET6 or pass the original full buffer to getnameinfo. Never copy a variable-sized sockaddr into the base struct. Verify IPv6 and scoped link-local interface/route records with address sanitization on an Apple platform.


## VP-017 — P1 — Fake local usbmux listener binds all interfaces and serves pairing credentials

Where: `Vendor/SideStore/Dependencies/minimuxer/Sources/Services/UsbmuxdProxyServer.swift:48,64-67,236-240`.

Why/what: The comment promises 127.0.0.1:27015, but `NWListener(using: .tcp, on: port)` has no loopback `requiredLocalEndpoint` and accepts connections on available interfaces. The unauthenticated ReadPairRecord message returns the complete pairing file, including pairing credentials, to any connecting client. This clashes with the intended local-only helper and can expose credentials on a reachable LAN when the libimobiledevice backend activates it.

Fix suggestion: Require a loopback local endpoint in NWParameters before constructing the listener, reject nonloopback peers as defense in depth, and scope supported packet requests. Verify loopback access works and LAN IPv4/IPv6 access is rejected. Do not rely on the documentation comment as a bind restriction.

## VP-018 — P2 — Restarting network observation reuses a cancelled monitor

Where: `Vendor/SideStore/Dependencies/minimuxer/Sources/Services/NetworkObserverService.swift:25,49-70,168-180`.

Why/what: stop cancels the sole NWPathMonitor and sets started=false; a later start calls start on that same cancelled monitor. NWPathMonitor cancellation is terminal, so the public stop/start lifecycle cannot restore network observation, leaving reachability/UI updates stale. Separate actor read and write also permit concurrent starts to both pass the alreadyStarted guard.

Fix suggestion: Own a new monitor per observation session, atomically transition stopped to starting, and finish/cancel the old stream and handler during stop. Verify stop/start receives new path changes and concurrent start callers produce one observer.


## VP-019 — P2 — Cancelled wireless-pair task clears and stops its replacement

Where: `Vendor/SideStore/Dependencies/minimuxer/Sources/Services/WirelessPairService.swift:45-50,90-100,116-120,156-165`.

Why/what: Starting a replacement cancels the old task and stores the new one. When the old task finishes/catches cancellation, its cleanup unconditionally sets activeStartTask=nil and stops shared advertising; trigger cleanup likewise removes whatever task is currently stored under the socket key. A cancelled old session therefore erases the replacement's tracking and may shut down its advertisement. Further Stop/replacement actions can miss the new work and UI receives stale completion events.

Fix suggestion: Assign a generation/request token to each task and only clear the slot, stop that session's advertisement, or deliver completion if it is still the active generation. Await teardown before starting shared resources. Verify rapid Start-Start, Trigger-Trigger on one target, and Stop-Start flows.


## VP-020 — P2 — Stop wireless pairing cannot interrupt blocking accept

Where: `Vendor/SideStore/Dependencies/minimuxer/DeviceGateway/idevice/IdeviceGateway.swift:1891-1896`, `Common/TCPAcceptor.swift:57-64`, `Sources/Services/WirelessPairService.swift:169-184`, `Common/FFIDispatcher.swift:19-27`.

Why/what: The host pairing task waits in blocking Darwin.accept on a socket local to syncStartWirelessPair. Stop only cancels the Swift task; withFFIDispatch does not propagate cancellation, and nothing closes the accept socket. Cancelling the pairing screen before any peer connects leaves the GCD thread, pairing handle and task alive indefinitely. Repeated attempts accumulate waiting sessions and can produce late callbacks.

Fix suggestion: Own the acceptor in a cancellable session, close/shutdown its socket when the request is cancelled, or use a nonblocking/poll loop with bounded waits and cancellation checks. Pairing handshake and PIN waits should use the same cancellation token. Verify cancelling before a peer connects completes promptly without late PIN/completion events.


## VP-021 — P1 — Concurrent gateway calls race cached native pointer destruction

Where: `Vendor/SideStore/Dependencies/minimuxer/Common/FFIDispatcher.swift:15-20`; `DeviceGateway/idevice/IdeviceGateway.swift:75-77,110-118,242-246,2296-2310`; `DeviceGateway/libimobiledevice/LibimobiledeviceGateway.swift:79-83,173-187`.

Why/what: All async gateway methods dispatch synchronous work to the default global concurrent queue. Cached pairing/tunnel/adapter/handshake pointers and gateway state are mutable and unprotected. Network endpoint changes call invalidateConnection directly, freeing these native handles, while concurrent service actions can be using them. Two ensureConnection calls may also create/overwrite caches concurrently. @unchecked Sendable does not provide synchronization. This risks native use-after-free/double-free and intermittent installs/JIT failures.

Fix suggestion: Give each gateway a serial native-operation executor and ensure start/stop/invalidation/state setters run through the same ownership boundary. Keep blocking pairing accept/PIN sessions separately cancellable so they cannot monopolize that executor. Alternatively, use explicit handle leases/refcount ownership with synchronized cache replacement. Verify simultaneous readiness/installation and endpoint invalidation under Thread/Address Sanitizer.

## VP-022 — P2 — Container wipe suppresses all removal errors

Where: `Vendor/SideStore/Dependencies/minimuxer/DeviceGateway/idevice/IdeviceGateway.swift:2266-2272,2275-2285`.

Why/what: afcRemovePathRecursive is declared throwing but a failed afc_remove_path only logs and frees the error, then returns success. wipeContainer consequently announces completion even when files/directories remain. This makes its reset flow unreliable and can leave old data mixed with a subsequent restore/reinstallation.

Fix suggestion: Throw an error identifying the failed remote path, or return an explicit partial result requiring UI acknowledgement. Only announce a complete wipe once every intended item is removed. Verify denied/busy file removal is reported to the caller.


## VP-023 — P2 — Libimobiledevice Remote Pairing initializes without the UDID required by every operation

Where: `Vendor/SideStore/Dependencies/minimuxer/DeviceGateway/libimobiledevice/LibimobiledeviceGateway.swift:134-136,375-400,405-406`.

Why/what: cleanup clears cachedUDID. Remote Pairing startup sets rpIdentity but only the lockdown branch assigns cachedUDID. verifyInitialized nevertheless requires cachedUDID for both modes. First fetchUDID calls verifyInitialized before it can populate the cache, so the Remote Pairing backend remains permanently NotInitialized despite successful startup. withRPClient also hits this guard.

Fix suggestion: Validate initialization according to the selected protocol: a valid RP identity for Remote Pairing and a valid UDID for lockdown. Resolve/cache the live RP UDID after establishing the tunnel without depending on the very cache being resolved. Verify the full startup/readiness/installation flow for each backend/protocol combination.

## VP-024 — P2 — Libimobiledevice lockdown DDI mounting never uploads the supplied image

Where: `Vendor/SideStore/Dependencies/minimuxer/DeviceGateway/libimobiledevice/LibimobiledeviceGateway.swift:518-543,596-623`.

Why/what: The lockdown mount functions receive image Data but directly request mounting `/tmp/DeveloperDiskImage.dmg` or `/tmp/PersonalizedImage.dmg`, without sending that image to the device. The personalized helper is explicitly a placeholder and does not use its image parameter. Unlike the idevice implementation's upload-then-mount path, a clean device has no staged image at those hardcoded paths and mounting fails.

Fix suggestion: Implement a real upload/staging and required personalization sequence for lockdown, or make the unsupported backend/protocol combinations explicit before the user chooses them. Verify on a device without any pre-staged DDI.

## VP-025 — P2 — Libimobiledevice profile dump returns XML where callers require a filesystem path

Where: `Vendor/SideStore/Dependencies/minimuxer/DeviceGateway/libimobiledevice/LibimobiledeviceGateway.swift:709-729`; `Vendor/SideStore/Dependencies/minimuxer/Sources/MinimuxerImpl.swift:497-502`.

Why/what: The lockdown profile dump returns the serialized XML response string, while its API and the idevice/RP paths return a directory. ZIP mode treats that XML as a filesystem path and tries to zip it, causing export failure. Writes in the other dump paths use try? and can silently return an empty/incomplete directory as successful.

Fix suggestion: Normalize all backends to write the returned profiles into the requested dump directory, return that directory path, and propagate write failures. Define a structured result if raw data export is separately required. Verify raw and ZIP exports for both backends and denied/full-disk destinations.


## VP-026 — P2 — Libimobiledevice container wipe is a successful no-op

Where: `Vendor/SideStore/Dependencies/minimuxer/DeviceGateway/libimobiledevice/LibimobiledeviceGateway.swift:1130-1160`.

Why/what: Both protocol branches only ask House Arrest to vend the app container, then close the service. Neither lists nor deletes any files. The Remote Pairing branch also ignores the response error. A caller requesting reset receives success while all app data remains. This is distinct from the idevice backend removal-error suppression in VP-022.

Fix suggestion: After validating the House Arrest response, obtain an AFC client for that container and recursively remove the intended contents, propagating failed removals. If this backend cannot implement wiping, return unsupportedOperation and prevent a misleading successful reset. Verify a seeded container is actually emptied for both protocols.

## VP-027 — P2 — Remote Pairing debug operations report success without attaching

Where: `Vendor/SideStore/Dependencies/minimuxer/DeviceGateway/libimobiledevice/LibimobiledeviceGateway.swift:1196-1202,1231-1236`.

Why/what: Remote Pairing debugApp/debugProcess only connect to debugserver and log the requested identifier/PID; they never send a process lookup, attach, or detach command. The caller sees a completed JIT enable operation with no debugger action. VP-023 currently prevents this mode reaching the operation; fixing initialization alone exposes this additional incomplete implementation.

Fix suggestion: Implement the Remote Pairing debugserver protocol and validate responses through attachment/detachment, matching the lockdown branch's intended behavior. Until supported, throw a specific unsupported-operation error and reflect availability in the backend picker.

## VP-028 — P2 — Libimobiledevice app file APIs ignore their app identifier

Where: `Vendor/SideStore/Dependencies/minimuxer/DeviceGateway/libimobiledevice/LibimobiledeviceGateway.swift:1299-1306,1328-1335,1361-1368`.

Why/what: All three app file methods accept bundleId but never use it. They connect to ordinary AFC, whose filesystem is the shared media service rather than the selected app's House Arrest container. Compared with the idevice implementation's container session, listing/reading/stat-ing an app path can show unrelated media contents or fail despite the requested app file existing.

Fix suggestion: Vend the specified app container with House Arrest, validate the response, and use the resulting AFC connection for all three operations. Share a scoped container-client helper to keep backend semantics consistent. Verify two apps containing different same-named files return their own contents.

## VP-029 — P2 — Lockdown uploads discard the reported write length

Where: `Vendor/SideStore/Dependencies/minimuxer/DeviceGateway/libimobiledevice/LibimobiledeviceGateway.swift:913-922,1065-1077`.

Why/what: IPA and app bundle uploads send each entire buffer with one afc_file_write and ignore bytesWritten. A successful short write is therefore reported as a completed upload, followed by installing a partial package. UInt32(data.count) also traps for files larger than its range. App bundle empty files skip writing altogether even if an old staged file already exists.

Fix suggestion: Upload bounded chunks until the complete buffer has been acknowledged, reject zero-progress writes, and propagate errors with the path/offset. Explicitly truncate or recreate every staged destination, including empty files, and clean stale staged app content before reuse. Verify forced short writes and uploading a smaller/empty replacement file.


## VP-030 — P2 — CLI signing deletes its source when output aliases the input app

Where: `Vendor/SideStore/Dependencies/SideSign/CLI/CommandHandler.swift:98-104,167-172`.

Why/what: An .app is signed directly in place, even when an output is requested. If --output resolves to the input app (a natural explicit in-place invocation), the handler removes that directory and then tries copying the now-deleted source. The CLI fails after destroying the input app. This is dormant upstream CLI code, not the SideKick iOS signing path.

Fix suggestion: Compare standardized/resolved source and destination URLs before replacement. Treat identical paths as in-place signing, and use a temporary copied app plus an atomic final replacement for distinct output paths so output signing does not unexpectedly mutate the original.

## VP-031 — P2 — CLI app signing silently ignores explicit entitlements

Where: `Vendor/SideStore/Dependencies/SideSign/CLI/CommandHandler.swift:93-149,180-182`.

Why/what: SignContext exposes an entitlementsPath and the CLI accepts it, but .ipa/.app signing never reads that option. Only the raw binary branch loads the requested entitlement file. Users can supply an override, receive successful app signing, and discover that the requested capabilities were not applied. This is upstream CLI-only behavior.

Fix suggestion: Thread explicit entitlement overrides through AppBundleSigner with clear per-main-app/extension semantics, or reject the option for app/IPA targets with an actionable explanation. Verify the final signed entitlements match the requested override.


## VP-032 — P2 — CLI JSON anisette output includes plaintext progress

Where: `Vendor/SideStore/Dependencies/SideSign/CLI/CommandHandler.swift:722-744`.

Why/what: --json normally suppresses progress, but provisioning fresh device data still prints an encryption prompt and 'Device data saved...' to stdout before the JSON document. Even with a supplied device-data password, the save message remains. Scripts parsing stdout as JSON fail on the first successful provisioning. This is upstream CLI-only behavior.

Fix suggestion: Reserve stdout exclusively for the JSON result in JSON mode; send diagnostics to stderr and require explicit passwords in noninteractive execution. Verify stdout parses as exactly one JSON document for first-time and cached-device-data paths.


## VP-033 — P2 — Anisette purge misclassifies real Macs as simulated devices

Where: `Vendor/SideStore/Dependencies/SideSign/CLI/CommandHandler.swift:1064-1094`.

Why/what: purge-anisette identifies simulated machines using broad name/model matches including every noncurrent device whose model contains 'mac' or whose name starts 'macbook'. Real account Macs satisfy these tests and are removed without a selection/confirmation step. The command's label promises removal of simulated anisette machines, so the mismatch is consequential. Dormant upstream CLI only.

Fix suggestion: Track exact provisioned anisette identities and remove only those known IDs. If provenance is unavailable, list candidates and require an explicit device-ID selection, clearly distinguishing uncertain real devices from tracked simulated devices.

## VP-034 — P2 — CLI certificate creation silently discards the supplied CSR

Where: `Vendor/SideStore/Dependencies/SideSign/CLI/CommandHandler.swift:1108-1112`; `Vendor/SideStore/Dependencies/SideSign/CLI/CommandContext.swift:297`.

Why/what: The create action carries a csrPath but the handler patterns that value as underscore and always calls addCertificate, which generates its own identity. A user supplying a CSR gets a different certificate/key relationship than requested. Dormant upstream CLI only.

Fix suggestion: Load and validate an explicit CSR and route it to a certificate creation API that accepts CSR bytes; otherwise remove/reject the unsupported option. Verify the resulting certificate public key matches the supplied CSR.


## VP-035 — P2 — CLI team selection does not select the team used for portal mutations

Where: `Vendor/SideStore/Dependencies/SideSign/CLI/CommandHandler.swift:976-987,1099-1112,1154-1162,1186-1194,1240-1243,1519-1541`.

Why/what: --using-team-id selects a saved session/device data file, but executePortalOperation does not pass or enforce a selected Team. Each device/certificate/App ID/group/profile handler fetches the account's teams and unconditionally uses teams.first. An account belonging to multiple teams can therefore register/revoke/delete resources on a different team than the explicitly selected one. Dormant upstream CLI only.

Fix suggestion: Resolve a Team by options.teamID, or a persisted active-team identity, and pass that resolved Team into every operation. Reject a requested team absent from the authenticated account. Verify the same account with two teams mutates only the selected team.


## VP-036 — P2 — Portal type shorthand clashes with global team selection

Where: `Vendor/SideStore/Dependencies/SideSign/CLI/PortalCommandsParser.swift:54,77,101,139,572-573`.

Why/what: The parser first scans all arguments as global options. -t is both global team index and certificate/profile type. Thus `dev certs create -t development` tries interpreting 'development' as a team index and enters team selection or fails before the type parser runs; numeric/other inputs can unexpectedly select a team. Dormant upstream CLI only.

Fix suggestion: Give global team selection a distinct flag and parse each option in its subcommand context rather than scanning values multiple times. Reject unknown/missing values and add parser checks for type shorthand with and without a selected team.


## VP-037 — P2 — Global logging flags consume command and verification aliases

Where: `Vendor/SideStore/Dependencies/SideSign/CLI/main.swift:19-20,44,331-332,635-647`.

Why/what: run removes every -v and -d token anywhere before parsing. Those same tokens are registered as verify/display commands, profile validate/dump actions, and deep verification. Consequently `verify app.ipa -d` silently performs shallow verification, and command/action shorthand can vanish entirely. Dormant upstream CLI only.

Fix suggestion: Parse the command first and scope logging options separately; reserve unambiguous global long forms or accept globals only before the command. Verify deep mode is actually passed through for every advertised spelling, and each action alias reaches its intended handler.


## VP-038 — P3 — SideSign build helper masks failed builds through tee

Where: `Vendor/SideStore/Dependencies/SideSign/build.sh:2,7-18`.

Why/what: set -e does not make the outer pipeline fail when the build group fails; tee can exit zero, so callers see success after swift build/copy failed. The helper's build result is inconsistent with direct CI builds. Dormant upstream helper; the SideKick workflow does not invoke it.

Fix suggestion: Set Bash pipefail as well as errexit, or preserve the build group's PIPESTATUS explicitly. Verify a deliberately failing build returns nonzero while its complete log is retained.

## VP-039 — P3 — CLI example catalogue contains unsupported flags and commands

Where: `Vendor/SideStore/Dependencies/SideSign/sample-usages.sh:6-29,73-77,104-105,275-288,304-305,353`; `Vendor/SideStore/Dependencies/SideSign/CLI/main.swift:31-40,408-481,533-559`; `Vendor/SideStore/Dependencies/SideSign/CLI/PortalCommandsParser.swift:50-67,75-80`.

Why/what: Examples use --devicedata-password and --output-p12, neither recognized by the parser, plus p12 info and check commands which do not exist. Interactive server and failover examples omit the required source catalogue URL. Users following the certificate-export example can create a portal certificate without exporting its identity because the output option is ignored. Dormant upstream documentation/sample script.

Fix suggestion: Generate validated examples from the supported command registry, replace legacy flags with --machine-password/--output, remove or implement unsupported commands, and include catalogue URLs for selection/failover. Treat this as documentation rather than a runnable sequence of destructive account operations, and verify syntax with a no-network parser check.


## Coverage and limitations

The support coverage manifest contains 194 files. This worker completed 150 assigned files (25,037 text/metadata lines): 92 vendor support files, 39 minimuxer files, and 19 SideSign support/CLI files. The remaining 44 SideSign Sources files (8,609 lines) are delegated to the root reviewer and explicitly marked in this manifest; see the separate SideSign coverage. Every assigned text file was read through its final line in bounded line-numbered batches, except the minimuxer LICENSE, which was verified as an exact SHA256 duplicate of the fully read root license. Three .git indirection files were read; one PNG had signature, dimensions, size, and SHA256 inspected. A forced recursive actual-file inventory found no assigned file absent from the manifest.

39 findings: 4 P1, 29 P2, 6 P3. This is static inspection on Windows. No Apple device/runtime, Xcode compilation, native memory sanitizer, network service, or upstream CLI account command was run. Remote binary dependencies were inspected only through local package declarations and pinned metadata, not downloaded. Widget, upstream CI/build helpers, and SideSign CLI findings are explicitly retained upstream or dormant paths rather than shipped SideKick UI defects. Existing production modifications owned by other workers were not changed by this worker.


## Consolidated vendor findings — Historical artifacts and reference copies

Scope: `.build`, `artifacts`, `dist`, `action-logs-20261009124257`, root `action-logs*.zip` and `*.zip` files, and `sidestore-reference`. Git internals were excluded, including `sidestore-reference/.git`. Audit only; no production files or external services changed.





## WA-001 — P3 — Historical distribution package can be mistaken for the current release





**Where:** `dist/SideKick-72500e3/SideKick-unsigned.ipa` and `dist/SideKick-72500e3/SideKick-corresponding-source.tar.gz`.





**What and why:** The IPA identifies version `0.7.0`, build `0700`, and lives under an older commit directory. This is a historical snapshot, not proof that the current integrated build is misversioned: standalone project metadata and patched vendor release metadata already diverge (SK-032). The practical release-flow risk is selecting this local package as current without checking its commit and embedded metadata. Retaining an explicitly named old snapshot is itself legitimate.





**Improve:** Make release selection use an explicit commit/package manifest and validate the IPA metadata against the integrated build configuration. Keep historical snapshots clearly distinguished from a current download/default; do not replace them solely because a newer checkout exists.





## Inventory and review coverage





The coverage JSON records 1,647 non-Git files: 843 `.build` generated outputs (71,095,724 bytes), 13 files under `artifacts` (2,861,177 bytes), 2 files under `dist` (47,293,605 bytes), 11 extracted action-log files (183,310 bytes), 11 extracted failed-run log files, 2 root log ZIPs (68,047 bytes), and 765 reference-tree files (28,701,381 bytes).





All files have recorded paths, byte sizes, and SHA-256 hashes. The 843 `.build` outputs received generated-output inventory/hash review; their contents were not read, except both generated Swift test-runner/anchor files subsequently read in full by the parent reviewer. The 13 `artifacts` files received hash and archive/plist metadata review. Four timestamped artifact ZIPs each contain one IPA; the contained app bundles have no frameworks, extensions, provisioning profiles, or code-signature resource. The later standalone unsigned artifact has 12 IPA entries and version `1.0.0`/build `1`; earlier snapshots have 9 entries, and the first snapshot's app plist lacks bundle/version fields. These are historical build snapshots.





The `dist` IPA was parsed as a ZIP: it contains 186 entries, 7 framework paths and 24 extension paths, has no embedded provisioning profile, and has a `_CodeSignature/CodeResources` resource. This records a resource manifest; no claim is made that the IPA is signed. The corresponding source tarball was decompressed and its tar headers inventoried (1,095 members; 28,672,666 uncompressed member bytes); source member contents were not read.





Both root log archives were enumerated and their complete text members parsed for warning/error/failure lines and common credential patterns. The scan found zero credential-pattern lines. The action-log archive describes a failed Oct. 9 build due to a missing generated `Info.plist` path; the separate `failed-run.zip` shows a Swift immutable-property double initialization in `IPAImportStore`. The extracted action-log directory's 11 files hash-match the corresponding members of its ZIP. These are historical failures; the current project declares generated `Info.plist` output and initializes `fileManager` once. The earlier log also reports missing `SideKickIcon.svg` asset warnings; the current asset catalog references `SideKickIcon-1024.png`, so this warning is not reproduced in the current tree. The `AppIntents` metadata warning is informational.





The 765 `sidestore-reference` files hash-compare against `Vendor/SideStore`: 756 are byte-identical and 9 differ. The parent audit already fully read the 9 variant differences; those contents were not reread here. Differences, verified by SHA-256:





- `Build.xcconfig`


- `AltStore/Info.plist`


- `AltStore/SceneDelegate.swift`


- `AltStore/Intents/App Intents/AppShortcuts.swift`


- `AltStore.xcodeproj/project.pbxproj`


- `SideStore/Core/Operations/PipelineOperations/UpdateAppCertificateOperation.swift`


- `SideStore/Core/Operations/PipelineOperations/VerifyCertificateOperation.swift`


- `SideStore/DeepLinks/URLHandler.swift`


- `SideStore/Views/Settings/Advanced/UserCustomizations/UserCustomizationsView.swift`





The 756 identical files rely on the already completed Vendor source review. Neither group was independently source-read in this artifact pass. No additional actionable finding was confirmed from generated build outputs, historical logs, or reference-only metadata.





Parent reconciliation: all 11 extracted `failed-run` files are exact byte matches of the already parsed ZIP members; their hashes and duplicate review method are now recorded.


## Final coverage and verification

The report contains **134 detailed findings**: 33 SK, 11 SS, 12 VA, 38 VS, 39 VP, 1 WA. These include cleanup opportunities, source-backed UI recommendations, and functional defects. Dormant tvOS/widget/helper issues are distinguished from active iOS engine paths; this is not a count of independent current-release blockers.

The recursive inventory reconciles **2,507 non-Git project files**, excluding this audit's own generated readers, reports and ledgers: 95 first-party entries, 765 vendor project files, and 1,647 generated/artifact/reference entries. Three vendor Git indirection pointers were also read separately. No project path is missing from the final coverage map. All SideSign read cursors reach the final line; all AltStore/SideStore scoped entries are reviewed; saved first-party and AltStore hashes match the checked files.

Maintained source/text files were read through their end in bounded ranges. Asset/storyboard/plist resources received text or parsed metadata inspection as recorded. The 756 identical reference files reuse vendor review by verified hashes; all nine differing variants were reviewed against the current vendor. Generated binaries/build databases received inventory rather than reverse engineering; archives received member/metadata inspection; historical logs received complete text parsing rather than manual source review. Both generated Swift test files were read in full. The source tarball was enumerated, not independently rereviewed as another checkout.

Verification evidence: [coverage reconciliation](C:/Sidekick/docs/reviews/2026-10-12-audit-verification.json), [first-party ledger](C:/Sidekick/docs/reviews/2026-10-12-sidekick-coverage.json), [artifact/reference ledger](C:/Sidekick/docs/reviews/2026-10-12-workspace-artifact-coverage.json). Vendor ledgers reside beside this report.

Static inspection on Windows: no iOS device usability session, Xcode build, network credential operation, native memory sanitizer, or fresh Swift test execution was performed. No production fixes were made for this audit. Suggested verification describes work for future fixes, not tests already executed.

## Fix verification — 12 October 2026

All **134 original finding IDs** are accounted for in the targeted verification reports. Existing fixes were checked against the original triggers; residual defects were repaired. This pass followed this checklist and cited dependencies, without another whole-project scan.

- [SideKick findings](C:/Sidekick/docs/reviews/2026-10-12-verification-sidekick.md)
- [SideStore findings](C:/Sidekick/docs/reviews/2026-10-12-verification-sidestore.md)
- [Shared/dependency/helper findings](C:/Sidekick/docs/reviews/2026-10-12-verification-dependencies.md)
- [Integration and retained UI findings](C:/Sidekick/docs/reviews/2026-10-12-verification-integration.md)
- [Shared prefetch registry and concurrency regression](C:/Sidekick/docs/reviews/2026-10-12-verification-va005-supplement.md)

Reproducible vendor delivery: CI applies the original integration patches, embeds the VPN target, then applies `sidestore-audit-fixes.patch`, `sidesign-audit-fixes.patch`, and `minimuxer-audit-fixes.patch`. Vendor Git pins are unchanged; no upstream vendor push is required. The patch integration fixture checks the full sequence against pinned HEAD, including actual embedding and nested dependency fixes.

Executed checks: three Python integration/release fixture tests; five SideStore source guards; real shell pipeline failure propagation and build-wrapper failure fixtures; syntax and scoped whitespace checks. Swift prefetch regression execution, full Swift tests, Xcode compilation, device UI, Security.framework and native-memory checks remain delegated to macOS CI/device validation. Source-addressed status does not imply these runtime checks passed.
