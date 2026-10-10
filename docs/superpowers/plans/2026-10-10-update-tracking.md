# Update Tracking Implementation Plan

> Use superpowers:executing-plans inline. The user requires main only and authorized the rework and push.

Goal: Never represent an unknown or unverified GitHub build as installed/current.
Architecture: Foundation tracking policy and history client, shared atomic configuration store, explicit scanner/UI states and installation receipts.
Spec: docs/update-tracking-design.md.

- [x] Reproduce comparison/unknown-state failures with production-policy tests, then add typed check states and installed evidence.
- [x] Extract and test API history transport/decoding, unique revision identities, pagination, deterministic ordering and ambiguous filters.
- [x] Wire successful install/explicit confirmation and source-safe actor writes; remove premature provenance assertions and stale UI marker writes.
- [x] Show actionable uncertainty/setup/error states, preserve source edits and editable baselines, and invalidate stale installed observations.
- [x] Run core regression suite and syntax checks, request independent review, fix findings, commit and push main. Report CI status without prolonged waiting, per the user’s request.

Constraints: preserve existing vendor/dist changes, account credentials and historical source settings; no guest signing pipeline; do not download in background; no new branches; no claim of absolute compatibility or device testing.

Completion notes: final independent review found baseline-clear pending evidence and unordered release IDs; both reproduced and fixed. Self-update recovery uses LC_UUID from the downloaded and running executable, with pending evidence retained until the new binary runs. LiveContainer uses downloaded local IPA sharing, requiring recipient selection in iOS. Full device and Xcode behavior remain unverified locally.
Ruling: distinct release IDs are indeterminate rather than ordered numerically; differing releases remain reviewable, with no unproven newer-build notification. Cost: user may need to review a release manually.
Ruling: existing Vendor and dist changes excluded from this commit; no source changes made there.
