# Frontend, backend and handoff second pass

Root personally traced these paths, then assigned one task at a time to the existing three GPT-6 Luna agents at low reasoning effort. Root reviewed their changes and requested corrections before accepting them.

## Findings and changes

1. **URL update review used the new-install path.** It omitted queued-update completion cleanup. URL review now resolves the queued installed target and uses the existing update completion path. A missing target cannot silently become a new installation; a failed database lookup offers Retry and preserves the queue.
2. **LiveContainer detail accepted superseded update checks.** Configuration or guest observations could change while a request was running. Checks now compare generation, full configuration and current guest/connection identity after scanning and after restoring queued files. Stale results are discarded, with one bounded follow-up request.
3. **Expiry reminders disappeared on a database read failure.** A failed fetch became an empty app list and triggered obsolete-reminder deletion. Read errors now return before modifying notifications.
4. **Opening GitHub Tokens wrote the default token back to Keychain.** The binding observer treated passive loading as an edit and emitted unnecessary settings changes. Only explicit picker selection persists, and failed writes leave selection unchanged.
5. **Removing an Apple account destroyed installed-app team affiliation.** Core Data cascaded account deletion to teams and nullified installed-app relationships. Referenced account/team rows now remain inactive and hidden by the removal tombstone; session secrets are still deleted. Upstream sign-in reuses the account/team identifiers on reconnection.
6. **Default Update could choose the wrong signing team.** Both queued and GitHub update views matched only Apple account identity, then fell back to arbitrary saved sessions. The default now requires the installed account and team; explicit Options retains the separate-install flow.
7. **Canceled GitHub downloads could leave hidden persisted queues.** Cancellation between actor persistence and task resumption suppressed the UI job without removing its imported IPA. Canceled/superseded tasks now delete their exact returned import; ID and import-date matching protects newer replacements.
8. **LiveContainer Update lacked connection/availability checks.** A stale candidate could download or open a share handoff for a disconnected, snapshot or unavailable guest. Actions now validate eligibility and current candidate/configuration before download and again after file resolution before sharing.
9. **Editing the sole GitHub token overrode Public Access.** Automatic default selection ran on edits whenever the default was nil. It now runs only when adding the first credential to an empty vault.
10. **Import classification treated database failure as no installed apps.** The URL/GitHub import handoff now uses the throwing installed-app loader, cleans up the unsaved prepared file on failure and surfaces the error instead of silently treating an update as a new app.
11. **Confirm/Skip discarded downloaded updates before recording the decision.** GitHub detail now applies the expected-source mutation successfully before deleting the queue or dismissing. Missing installed targets, read failures and source conflicts preserve the download.

## Review boundaries

Root rejected an initial LiveContainer correction that shadowed the optional state guest with a captured nonoptional guest; it also missed the post-restoration notification boundary. The revised code reads current state explicitly and validates both boundaries. Root also required queued-target read errors to remain distinct from a successful empty lookup, and required import callback errors to appear in the still-visible parent view.

Review consisted of reading the modified code, callers, persistence relationships and asynchronous boundaries, plus Git whitespace/conflict checks. No Xcode, Linux, Swift compiler, build, test, simulator or alternate Swift validation environment was used. These are source-reviewed fixes; compilation and phone behaviour remain unverified.

Existing local changes in Vendor/SideStore and the untracked dist directory are outside this pass and are excluded from the commit.
