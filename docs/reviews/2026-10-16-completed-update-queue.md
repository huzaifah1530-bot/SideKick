# Completed update queue — 16 October 2026

The user clarified the previous confirmation issue: it presented through the normal app listing, but failed through the top Updates section. Both routes share `InstallConsoleView`; the prior visible confirmation change removes their dependency on modal-alert presentation. Device confirmation of that change is still pending.

The new screenshots show SideKick up to date while its IPA remains queued after self-update. Shared installation records a pending self-update receipt, and next-launch loading verifies the running executable before recovering the receipt. However, queue deletion lived only in UI completion callbacks. Replacing SideKick can terminate that process before its callback clears the persistent import index, while receipt recovery never deleted the queued import. This explains how installed-build tracking and the queue can disagree.

## Changes and boundaries

After confirmed successful installation, the shared service removes the exact queued import (using the existing ID plus import timestamp deletion path), rather than depending exclusively on whichever view initiated it. Ordinary nonqueued library imports keep their existing behavior. The old running process does not delete a pending self-update until its binary identity matches the requested IPA.

On catalogue loading, inspect SideKick's actual running executable and Info.plist. Remove only explicitly targeted queued self-updates matching that installed target ID, version, build and nonempty executable identity. This recovery also fixes existing stale queues without requiring another successful update or an outstanding GitHub receipt. It is independent of the selected GitHub source, including migration from Actions to Releases. A matching version label alone is insufficient. Newer/different binaries, different builds/versions, other teams, guest targets, missing identities and ordinary library imports remain intact. No pairing/account/signing-source files are touched.

The download-job validator now drops stale in-memory jobs whose exact import no longer exists, while retaining genuine missing-file errors for entries still in the queue. Concurrently replaced jobs and active downloads are protected. Existing view callbacks remain safe because import deletion is idempotent. Cleanup errors are handled separately from installation success; failed self-queue cleanup is retried on the next catalogue load.

Recovery only removes an IPA matching the running build. An older leftover that no longer matches after installing a different build is retained for manual review; it cannot safely be treated as completed from its version label alone.

## Verification

The integration fixture first failed against the old missing-cleanup wiring. New core cases cover exact self matching and preservation of newer, ambiguous/unverified, nonqueued, other-team and guest imports. Local Python tests and diff checks are run before push. Swift behavioral tests and the full iOS build require macOS CI; device self-replacement and queue removal remain unverified. The user asked to report build results themselves: no build status/log monitoring or release publishing was performed.

Graphify was consulted before source navigation and refreshed after code edits. Its vendor graph is a navigation aid; the shipped target is the patched SideStore integration. Work stayed on main, preserving unrelated VPN, vendor, audit and graph setup changes. No subagents were used.
