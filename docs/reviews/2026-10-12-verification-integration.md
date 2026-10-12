# Integration and retained UIKit finding verification — 12 October 2026

This pass follows the existing Markdown checklist, inspecting cited code and relevant diffs only. Existing fixes were retained. Source-level resolution is not Apple runtime acceptance.

| ID | Verification / changes | Evidence and limits |
|---|---|---|
| SK-032 | Standalone project is explicitly obsolete in project.yml and README; integrated SideStore bootstrap/version is authoritative. | CI fixture applies all integration patches to pinned vendor HEAD and executes VPN embedding. Actual Xcode build unavailable. |
| SK-033 | Integrated patch removes launch notification authorization while retaining background-fetch interval setup. | Fixture asserts no requestAuthorization in prepareForBackgroundFetch. Actual onboarding permission UI requires device. |
| VA-001 | Shared operation activity predicate uses progressLock.withLock, like mutation/accessors. | Reviewed matching lock ownership; Thread Sanitizer pending. |
| VA-002 | Previous nonempty build is preserved with $0, not empty string. | Equal build values now compare equal; background/device delivery pending. |
| VA-003 | Display link targets a weak button proxy; only starts with a window and countdown; nil/detachment/expiry invalidates it. | Checked lifecycle paths; UIKit Memory Graph pending. |
| VA-004 | Empty placeholder no longer disables scrolling; Browse already sets alwaysBounceVertical. | Empty-load retry path stays available; device gesture pending. |
| VA-005 | Generation ownership fixes task replacement cleanup; shared bookkeeping cleanup is being verified separately. | Old completion cannot remove replacement; see supplemental verification. |
| VA-006 | Invalid screenshot fallback throws an indexed decoding error and removes newly inserted partial screenshots, terminating the loop. | Traced malformed fallback and context cleanup; Core Data decode fixture pending. |
| VA-007 | Reconfiguration requires nonempty source and matching actual section/item counts. | Checks zero/nonzero sections; UIKit transition test pending. |
| VA-008 | Min/max incompatibility guidance is separated, with neutral mixed summary. Found fix introduced immutable message mutation; changed let to var. | Observed failing source invariant before edit, passing after; Swift/UIKit compilation pending. |
| VA-009 | Confirmation precedes filesystem mutation; previous backup staged; current moved to rollback before replacement; failure restores rollback. | Cancellation performs no writes; disk failure/runtime restore injection pending. |
| VA-010 | Update flow awaits fetchSources directly and clears busy state/completion on success/failure. | No missing-notification wait remains; no-sources device fixture pending. |
| VA-011 | Recommended source failures collected under context queue, successful rows retained, error/footer retry exposed. | Inspected partial/all-error cases; fetch/UI runtime pending. |
| VA-012 | Deep-link task catches fetch errors; deferred busy/spinner reset; failed URL retained, newer pending URL processed. | Inspected failure and concurrent request sequencing; UIKit retry pending. |
| WA-001 | Historical dist README labels snapshot; release manifest binds package hashes, integrated app metadata and source revision. Fixed conditional xcconfig selector parsing. | Two executable fixture tests failed before fix and now pass; mismatched build rejected. No new IPA was built. |

Additional integration repair: existing AppDelegate hunks had mismatching whitespace/incomplete context and failed git apply against pinned vendor HEAD. Reconstructed the same intended primary patch against exact baseline; executable fixture now applies the five-patch CI sequence and VPN embedding successfully, verifies startup/notification routing and resulting version. LF checkout matches macOS CI; Windows CRLF source normalization is explicit in the test.

No Swift toolchain is installed on Windows or WSL Ubuntu. Xcode/UIKit, Security.framework, private signing/device protocols, and device acceptance remain unexecuted. Python source guards are not a substitute for Swift builds.
