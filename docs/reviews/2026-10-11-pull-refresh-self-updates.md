# Pull-to-refresh and SideKick self updates

The user is running build 87 and reports that pulling down appears not to check GitHub and that SideKick cannot update. Root compared build 87's source with current main and traced the installed target, configuration, scan ownership, status rendering and download paths. No phone state was available, so these are source findings rather than a confirmed diagnosis of that specific installation.

## Findings and implementation

- Build 87's Home owned/canceled its repository scan and published after the combined scan finished. Current main already owns scans in AppEnvironment and publishes checks individually. Ordinary local reloads do not cancel slow checks.
- Current manual refresh forced a repository check but returned after local catalogue loading. The pull spinner could finish before the network check. Only `.refreshable` now calls `awaitPendingGitHubChecks` after the forced local reload. It awaits the owned scan and an already-requested follow-up. Pause/cancellation prevents waiting on subsequent scans; the caller never cancels the app-owned scan. Startup and other reload callers remain fast.
- The status row was hidden whenever Updates contained any candidate or manual queue. A separate GitHub status section now always renders progress and outcomes, with explicit unconfigured status and a setup link for the running SideKick target.
- Self-update source defaults previously existed only in the unsaved settings form. With no stored configuration the scanner returned `notConfigured` without making a repository request. After a successful local load, the running installed SideKick target now gets a saved default Actions source before the scan: `huzaifah1530-bot/SideKick`, `ios-build.yml`, `main`, and the standard or VPN artifact matching the installed extension. Other apps are unaffected; custom self sources remain authoritative.
- Explicit successful removal of SideKick's source persists an opt-out; explicit settings save reenables it. Older builds did not record this opt-out, so an upgrade with no source receives the default once. No installed baseline or receipt is fabricated from a build/version label. An unverified installed build still produces a reviewable candidate rather than pretending the latest build is installed.
- Downloading an Actions artifact without a credential previously reached a generic authentication error. The downloader now rejects missing/blank credentials with an actionable token prompt. Public release download behavior is unchanged. GitHub documents Actions read permission for [artifact downloads](https://docs.github.com/en/rest/actions/artifacts#download-an-artifact), while public artifact listing can be unauthenticated.

## Reviewed scenarios

Root traced first startup with no self source, saved custom source, successful source removal followed by refresh, standard/VPN variants, pull during an existing scan, queued follow-up, pause/background cancellation, existing manual queue, unconfigured target, unknown baseline and missing Actions credentials. The existing source/observation checks still suppress superseded results. The three existing agents received individual tasks; root reviewed each result before assigning the next.

Existing [build 92](https://github.com/huzaifah1530-bot/SideKick/actions/runs/38131138882) succeeded for commit 117dced. That is evidence for the preceding commit, not these new changes. Source inspection and Git whitespace/conflict checks were used for this patch; no Swift compiler, Xcode, Linux, build, test or alternate validation environment was used, and no CI rerun was requested. Phone behavior remains unverified.

Existing Vendor/SideStore changes and dist files are excluded from the commit.
