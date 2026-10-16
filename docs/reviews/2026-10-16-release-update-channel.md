# SideKick self-update channel — 16 October 2026

The user requested release-based self-updates and a prominent README feature-status notice, and explicitly prohibited creating releases. No release was created or published. The user also requested no build monitoring; no workflow status or build logs were fetched for this change.

The default self-update configuration now selects GitHub Releases and the exact matching IPA filename: `SideKick-unsigned.ipa`, or `SideKick-vpn-unsigned.ipa` when the built-in VPN extension is present. On catalogue reload, `AppEnvironment` calls `ensureSelfUpdateConfiguration` for the running bundle. That method also migrates existing configurations matching the old shipped repository/workflow/main/artifact defaults. Other repositories, custom workflows/assets, existing release sources, opt-outs and other apps remain intact.

An optional per-configuration migration marker is backward compatible with saved JSON. A migration keeps the token association and original product ID, but starts fresh release tracking because Actions receipts, pending self-update evidence and skipped-build keys cannot identify a release. Explicit self-update settings saves mark the choice as reviewed, allowing a user to return to Actions without being migrated on every launch. Existing release discovery/download code is reused; there is no fallback to Actions when releases are absent. No release metadata or asset was invented or published.

The README starts with an early-release notice that core sideloading operations (installing, signing, refresh and automatic refresh) are the supported focus, while other visible features are under development and not guaranteed to work. Automated tests do not establish device functionality for those features.

Regression cases cover both IPA variants, old-default migration with obsolete tracking removed, preserved custom/explicit Actions choices, and old JSON without the optional marker. Local checks passed: 9 release/connection/transfer fixtures and 2 vendor-composition fixtures; Darwin behavior is skipped on Windows. The new Swift core tests and the full iOS build require macOS CI and have not been observed, in accordance with the user's request to report the build result themselves.

Graphify was used before source exploration and refreshed after edits. Work stayed on main and preserved unrelated VPN, vendor, audit and graph setup files. No subagents were used.
