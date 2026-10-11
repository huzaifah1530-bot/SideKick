# Frontend, backend and handoff third pass

Root personally inspected the code and existing GitHub Actions results, then assigned narrow fixes to the same three GPT-6 Luna agents, one task per agent at a time. Root read each implementation and requested corrections before acceptance.

## Findings

1. **ZIPFoundation type annotation blocked the build.** Existing Actions run #90 reported that `Archive.Entry` is not a nested type. The pinned ZIPFoundation 0.9.20 source declares a top-level `Entry`; the annotation is now `ZIPFoundation.Entry`. This was a regression from the first review pass that root missed.
2. **History requests ignored credential changes.** GitHub update settings could publish an old token's results/error or append another token's second page. Credential-aware request checks and invalidation now reset history and pagination while preserving the installed baseline. Loading older history requires an initial loaded page.
3. **VPN configuration mutations raced operation leases.** Authorize/remove/mode changes checked for active leases only before suspending. A shared exclusion now spans their awaits, and acquire rejects a mutation before inserting its lease. A revision also rejects preference reads that span a completed mutation.
4. **Unresolved manual queues were hidden or treated as new installs.** Home excluded missing queued targets from Updates, then either hid the IPA behind another installed copy or routed it through Ready to Install. Explicit missing targets and ambiguous legacy targets now stay visible in Updates and use queued-target review. Ordinary legacy imports without matches retain their original behavior.
5. **Files/incoming import decisions used a possibly stale catalogue.** A failed catalogue refresh retained the old snapshot, which was then used to classify the IPA. Classification now requires a fresh successful installed-app read, captures its matching targets for the dialog, and surfaces read failures without silently saving as a new app.
6. **Update notifications outlived the decision that generated them.** The scheduler awaited notification APIs without checking current source/skip/installed state. It now checks configuration before changes and after posting, suppresses superseded candidates and avoids writing their deduplication marker. Post-add cleanup is best effort and removes only that identifier.
7. **Manual Refresh All discarded its outcome.** The frontend now reports full success, partial failure, total failure or no attempted apps using the returned counts. A zero-attempt result does not claim that nothing is installed. Scheduled automation remains silent.
8. **An IPA-index read failure looked like an empty queue.** App management now preserves its pending update state and offers Retry on library read failure, instead of clearing the queue display or falsely claiming the file is no longer queued.

## Existing GitHub Actions checked

The latest 20 runs were inspected. At the final check, six had failed and three were canceled; the other eleven completed runs succeeded. Existing logs were read, without dispatching a build or rerun.

| Run | Recorded result | Evidence |
| --- | --- | --- |
| [#90](https://github.com/huzaifah1530-bot/SideKick/actions/runs/38129606830) | Failed | IPAImportStore's `Archive.Entry` annotation. Source correction included here. |
| [#91](https://github.com/huzaifah1530-bot/SideKick/actions/runs/38130415452) | Failed | Previous second-pass commit c2f15d3 failed with the same `Archive.Entry` diagnostic as #90. Source correction included here. |
| [#79](https://github.com/huzaifah1530-bot/SideKick/actions/runs/38051008631) | Failed historically | Missing `isMacDirtyCowSupported`; later runs #80–89 succeeded. |
| [#77](https://github.com/huzaifah1530-bot/SideKick/actions/runs/38048516432) | Failed historically | List separator closure syntax; later successful runs followed. |
| [#76](https://github.com/huzaifah1530-bot/SideKick/actions/runs/38047897010) | Failed historically | List separator syntax and unqualified Button; later successful runs followed. |
| [#75](https://github.com/huzaifah1530-bot/SideKick/actions/runs/38047270040) | Failed historically | List separator context and unqualified Button; later successful runs followed. |

## Review limits

Source/call-site/persistence/interleaving review and Git whitespace/conflict checks only. No local Swift compiler, Xcode, Linux, build, test, simulator or alternate validation environment was used. No CI dispatch or rerun was requested; the repository's existing automatic push workflow is unchanged. Existing CI diagnostics are evidence of past runs, not proof that these new fixes compile or work on a phone.

The pre-existing Vendor/SideStore changes and untracked dist directory are excluded.
