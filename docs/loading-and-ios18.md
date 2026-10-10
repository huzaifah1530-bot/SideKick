# Catalogue loading and iOS 18 compatibility

## Source findings

The previous Home implementation owned installed apps, guest metadata and update results in view state. Every local reload cancelled the GitHub task. Its scanner checked installed apps first, then rescanned LiveContainer directories, then checked guests; Home published results only after the entire scan and queue restoration finished. A slow repository could therefore delay guest discovery and every update row. Navigating away cancelled that work again.

The LiveContainer library also began with an empty, conditional List section and attached its bootstrap task to that section. It now renders an app-owned catalogue instead of depending on that section being materialized.

## Current flow

1. AppEnvironment starts the database and publishes installed metadata and cached LiveContainer metadata before setting its database state to ready.
2. Home reads those observable catalogues directly. Icons load afterward and cannot hold back the initial rows.
3. LiveContainer directory discovery runs independently of repository requests and publishes after each directory scan.
4. GitHub checks run at most three repositories concurrently. Each completed result is published immediately. Queue restoration and notification delivery run after row publication.
5. Local reloads coalesce and preserve an ongoing repository scan. Changed targets or explicit refresh requests queue a follow-up scan. Navigation does not cancel the app-owned scan. Backgrounding suspends network checks; foregrounding requests another check.
6. Results retain their checked configuration and target observation. Source edits, skipped builds and completed installations supersede old results. Network failures retain previously discovered candidates and show failed-check status.
7. Update checks stop fetching older workflow artifacts once the latest matching download is found. History-selection and import pages still fetch their full page.

Diagnostics log local publication counts and each GitHub result state. These provide device evidence if startup remains problematic; no tokens or credentials are logged.

## Compatibility

The standalone project, integration patch and optional VPN-extension target deploy to iOS 18. Xcode 26 remains the build SDK because the source contains availability-gated iOS 26 APIs. Native controls use the installed system's appearance. The custom glass helper falls back to regular material, and the hidden navigation-indicator modifier falls back to the standard disclosure indicator on iOS 18.

## Validation status

Only direct source review was performed, following the user's restriction on builds, tests, simulators and external code checkers. Compilation and device behavior are not confirmed.

On iOS 18 and iOS 26, device validation should cover cold launch with saved apps and linked guests, offline GitHub requests, one slow repository alongside another successful repository, navigation during a check, reconnecting a guest directory, skipping a build during an in-flight request, foreground/background transitions, and standard-material/disclosure fallbacks. Local app and cached guest rows must appear without pulling to refresh, independently of check completion.
