# LiveContainer and app-management fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Discover and launch real LiveContainer guests, reuse GitHub update tracking, and fix storage, account, Update, and baseline controls.

**Architecture:** Separate guest records from installed signing records. A shared actor owns bookmarked connections and read-only scanning; a common GitHub target descriptor preserves existing normal-app IDs and namespaces guests. Filesystem cleanup uses validated owned roots and explicit source-removal controls.

**Tech Stack:** Swift, Foundation, SwiftUI/UIKit, JSON persistence, existing GitHub/SideStore services, XCTest via a small Swift package, macOS Actions.

**Spec:** docs/livecontainer-investigation.md (approved by the user on 10 October 2026).

## Global Constraints

- First phase excludes automatic guest IPA installation and any modification of LiveContainer.
- Never advance an installed baseline on download or launch.
- Preserve existing signing behavior and pre-existing Vendor/SideStore and dist changes.
- Device access/launch and cross-team data continuity require explicit physical-device validation.

## Review Focus

- Duplicate guest IDs in different locations must retain separate source associations.
- Revoked access/partial scans must retain metadata and exact baselines.
- Late scans/history responses must not overwrite changed connections or user selections.
- Storage removal must reject external paths/symlinks and protect running operations.
- Guest update candidates must never reach normal signing/install queues.

### Task 1: Scanner, identity, and persistence

**Files:** SideKick/Models/LiveContainerModels.swift; SideKick/Services/LiveContainerScanner.swift; SideKick/Services/LiveContainerStore.swift; Tests/SideKickCoreTests; Package.swift.
**Interfaces:** LiveContainerScanner.scan(directory:connectionID:) throws -> LiveContainerScan; LiveContainerStore.shared exposes snapshot/link/rescan/disconnect/forget; guest.id derives from connection + folder.

- [ ] Add failing XCTest cases for malformed/missing plists, duplicates, read-only scans, missing/partial bundles, rescan merge, persistence restart, and unsafe paths.
- [ ] Run tests against absent implementation; record available runner limitations.
- [ ] Implement bounded read-only metadata/icon parsing and scoped/coordinated bookmark access with serialized JSON writes.
- [ ] Run core tests; review connection replacement, cancellation, and retained failure state.

### Task 2: Shared GitHub targets and baseline corrections

**Files:** GitHubUpdateConfiguration.swift; GitHubUpdateConfigurationStore.swift; GitHubUpdateService.swift; GitHubUpdateScanner.swift; GitHubUpdateSettingsView.swift; GitHubUpdateNotificationScheduler.swift.
**Interfaces:** GitHubUpdateTarget(id:name:version:kind:) independent of InstalledAppSummary; effectiveBaselineKey uses last-installed first; store.shared serializes source changes.

- [ ] Add failing tests for Build 52/81 override, namespaced guest target identity, JSON backwards compatibility, and exact-build comparison.
- [ ] Generalize service/scanner without creating fake installed signing records; preserve exact historical baselines and user edits.
- [ ] Include connected eligible guests in existing notifications/background/shortcut checks and use guest-specific wording.
- [ ] Verify core tests and normal-app call-site compatibility.

### Task 3: Native guest UI and launch

**Files:** Views/LiveContainer/LiveContainerViews.swift; AppEnvironment.swift; HomeView.swift; SideKick/Info.plist; patches/sidestore-sidekick.patch.
**Interfaces:** LiveContainerSection renders guests separately; connection/detail pages consume store snapshots; launchURL uses URLComponents and folder identity.

- [ ] Add launch encoding/invalid scheme tests before launch implementation.
- [ ] Add directory linking, rescan/reconnect/disconnect/change/forget, guest details, source/baseline controls, and explicit installed/skip actions.
- [ ] Declare verified query schemes in both build paths; handle unavailable/missing guests without claiming launch success.
- [ ] Verify source/build checks and document iPhone smoke tests.

### Task 4: Storage and account/update flows

**Files:** SideKickStorageCleanup.swift; SideKickStorageUsage.swift; SideStoreSettingsPages.swift; AppManagementView.swift; GitHubUpdateDetailView.swift.
**Interfaces:** cleanup entries classify owned temporary/signing sources; deletion validates containment and running-operation state; all-account options route same-team refresh or source-based other-team installation.

- [ ] Add failing containment/symlink and retained-source classification tests.
- [ ] Implement safe deletion controls, owner/retention explanations, cleanup results, and recoverable source import.
- [ ] Make Update leading/icon-labelled with always-visible Options and show all saved accounts with honest operation capabilities.
- [ ] Verify no same-team guard removal, no automatic original removal, and no guest pipeline routing.

### Task 5: Integration validation, documentation, and push

**Files:** .github/workflows/ios-build.yml; README.md; docs/settings-functionality.md; docs/livecontainer-integration.md.

- [ ] Add core tests before integrated iOS build and enable validation on codex branches.
- [ ] Run local available checks, fresh independent review, core tests, and exact-commit CI where available; repair failures.
- [ ] Record device-only and unsupported behaviors and all material limitations.
- [ ] Commit only task files and git push the codex/livecontainer-integration branch; preserve unrelated work.

## Execution ledger

Ruling: Execute inline in the existing checkout on a dedicated branch. The user's “go on and git push when you're done” authorizes continuation and publishing the branch; preserve unrelated checkout changes without another approval round. No worktree is necessary for this single executor. A fresh reviewer will inspect the final diff.

Ruling: No local Swift/Xcode is currently on PATH. Seek an available Linux/Windows Swift runner for Foundation tests, and run the integrated iOS build in macOS CI. Do not claim a test passed when only source inspection ran.


Progress: Implementation and independent review fixes are complete. Foundation tests pass (25), all Swift sources parse, and the integration patch applies to the vendor index. The Linux toolchain was installed in WSL; no iPhone execution has occurred. Review fixes isolate normal installations/queues by resigned identity, preserve unambiguous legacy associations, show reconnect-required accounts, validate retained ownership by stable IDs, retain pagination after empty pages, and promptly cancel stalled provider scans. Push and exact-commit macOS CI remain the final validation steps.
