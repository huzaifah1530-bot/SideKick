# Review bug fixes implementation plan

**Goal:** Address the three reported app behaviours and the concrete backend/handoff findings from the read-only review.

**Execution:** Three existing GPT-6 Luna agents with low reasoning; the commander assigns one task at a time, reviews every change, sends corrective feedback, and performs a final review before pushing main.

**Constraints:** No Xcode, Linux, Swift compiler, simulator, builds, test execution, or other software environment to validate Swift. Source inspection and Git checks only. Do not modify Vendor/SideStore, dist, or existing unrelated changes. Agents do not commit, push, spawn agents, or change unassigned files. CI and physical-device behaviour remain unverified by this session.

## Task 1 — Startup and LiveContainer publication

- Inspect the current app-owned startup flow and its UIKit hosting integration. Do not claim historical causes establish the current device failure.
- Ensure Home requests its local catalogues when it appears, independently of GitHub, incoming imports, account capacity, and scene activity changes.
- Ensure LiveContainer has a stable rendered observation/bootstrap path, local cached metadata loads independently of network checks, and failures are visible.
- Keep existing coalescing and generation protections. Avoid repeated network scans and unbounded reload loops.
- Owned files: App/AppEnvironment.swift, Views/Root/ContentView.swift, Views/Home/HomeView.swift, Views/LiveContainer/LiveContainerViews.swift, docs/loading-and-ios18.md.

## Task 2 — Retained IPA sources and metadata

- Persist direct URL downloads as managed local IPA files. Future installation/share operations use the saved local file, preserving the source URL only for provenance.
- Migrate old URL-only records when first successfully downloaded; validate bundle/version/build/executable identity before installation. Do not silently install a changed source. Manage copy/save failures and cancellation without orphaning files or overwriting newer queue state.
- Identify only the top-level Payload/*.app/Info.plist. Use relative archive paths for icons.
- Owned files: Services/IPAImportStore.swift, Models/ImportedIPA.swift, Views/Home/IPASharingViews.swift, Tests/SideKickCoreTests/IPAImportIndexTests.swift (optional), new focused metadata helpers and tests (optional).

## Task 3 — Global signing coordination and honest results

- Serialize the full account-switch/prepare/operation/restore scope across all SigningAccountStore instances, including sign-in/removal/export and developer inventory.
- Account preparation failures restore the prior session when possible. Restoration or receipt persistence failure after a successful operation must not report that successful installation/refresh as failed.
- Use the resigned installation identifier for expiry notifications; clean up obsolete reminders safely.
- Owned files: Services/SigningAccountStore.swift, Services/SideStoreOperationService.swift, Services/ExpirationNotificationScheduler.swift, Services/SideKickCertificateExport.swift (only if needed), new focused signing coordination helper (optional).

## Commander review checklist

- Trace cold startup, view reappearance, inactive/active transitions, failed local reads, and guest catalogue updates.
- Trace URL import, older URL record migration, changed/missing source, replacement/deletion during an await, retained-file cleanup, and queue identity changes.
- Trace two store instances overlapping inventory/signing, cancellation, reentrancy, restore failures, successful installation followed by receipt failure, and two teams' expiry reminders.
- Read every diff, check exact call sites and type usage, inspect Git whitespace/diff status, and preserve pre-existing submodule/dist changes.
- Commit only reviewed task files. Push main without force after verifying the remote branch has not advanced.

## Review record

- Initial main and origin/main: 9da41829125eb99530dd359b7a3d1ed6d39c46b1.
- Existing unrelated status: modified Vendor/SideStore working tree and untracked dist/.
- Implementation and device validation are explicitly separate: static review cannot establish that the reported loading behaviours are fixed on a phone.
- Task 1 accepted after commander review: Home appearance/tab return requests local reload/discovery; the LiveContainer section renders a stable loading/empty/error/guest state; concurrent snapshot requests receive a follow-up read. Historical startup causes are not claimed as current device proof.
- Task 2 accepted after commander corrections: retained URL copies, legacy migration with competing-reader recheck, reviewed-source identity validation, actual-row deletion cleanup, top-level archive metadata and relative icon paths. Direct downloads now have cancellation/generation ownership; unsaved copies are discarded on cancellation/failure/navigation; temporary files preserve PID naming for crash cleanup.
- Task 3 accepted after commander corrections: a shared MainActor gate rejects overlapping account scopes; preparation failures attempt prior-session recovery; ancillary errors preserve actual operation success. Certificate export validates and captures the intended P12 without global certificate mutation and retains URL encoding. Expiry requests identify separately signed installations.
- README follow-up accepted: storage and signing descriptions match the new implementation and explicitly retain the source-only validation limitation.
- Review choices: global account scopes reject overlap instead of queueing it; old URL records lacking optional build/executable metadata compare only the metadata originally known; startup changes provide resilient retries without asserting an unobserved current-device root cause.
- No builds, Swift compiler invocations, tests, simulators, Linux, or external Swift validation tools were used. Git whitespace checks and source/caller inspection are the validation evidence for this session.
