# SideKick self-update channel — 16 October 2026

## Published asset filename follow-up

After the user published [SideKick v0.8](https://github.com/huzaifah1530-bot/SideKick/releases/tag/Releases), the GitHub Releases API showed the actual assets `SideKick.ipa` and `SideKick+Vpn.read.release.description.ipa`. These did not match the earlier assumed unsigned filenames. The default selector now uses those exact published names for the regular and built-in VPN variants respectively. Existing configurations using the earlier known release-default filenames are corrected even when the Actions-to-Releases migration marker is already set; custom filters and explicit Actions choices remain intact. A filename-source change clears obsolete tracking evidence, preserving the token association and product ID.

Regression coverage includes both assets in a single synthetic release and requires the production history client to select exactly the installed variant. Exact-name selection handles the literal plus sign without a broad wildcard that could cross variants. Prior release-default migration is covered separately. No asset, tag or release was renamed or published by the agent, and no build monitoring was performed.

The friend’s separate sign-in report currently identifies Apple authentication response with HTTP 503 after a reported 200 response; the reported numeric sequence alone does not establish an Apple error code or root cause. Provider mode/client configuration and build are still being collected. Do not classify this as GitHub failure, assume an Anisette outage, clear account/provisioning data, or add broad automatic retries without evidence.

The user requested release-based self-updates and a prominent README feature-status notice, and explicitly prohibited creating releases. No release was created or published. The user also requested no build monitoring; no workflow status or build logs were fetched for this change.

The initial self-update change selected GitHub Releases with the assumed asset names `SideKick-unsigned.ipa` and `SideKick-vpn-unsigned.ipa`; the published-filename correction above supersedes those names. On catalogue reload, `AppEnvironment` calls `ensureSelfUpdateConfiguration` for the running bundle. That method also migrates existing configurations matching the old shipped repository/workflow/main/artifact defaults. Other repositories, custom workflows/assets, opt-outs and other apps remain intact; known obsolete release-default filenames are also corrected as described above.

An optional per-configuration migration marker is backward compatible with saved JSON. A migration keeps the token association and original product ID, but starts fresh release tracking because Actions receipts, pending self-update evidence and skipped-build keys cannot identify a release. Explicit self-update settings saves mark the choice as reviewed, allowing a user to return to Actions without being migrated on every launch. Existing release discovery/download code is reused; there is no fallback to Actions when releases are absent. No release metadata or asset was invented or published.

The README starts with an early-release notice that core sideloading operations (installing, signing, refresh and automatic refresh) are the supported focus, while other visible features are under development and not guaranteed to work. Automated tests do not establish device functionality for those features.

Regression cases cover both IPA variants, old-default migration with obsolete tracking removed, preserved custom/explicit Actions choices, and old JSON without the optional marker. Local checks passed: 9 release/connection/transfer fixtures and 2 vendor-composition fixtures; Darwin behavior is skipped on Windows. The new Swift core tests and the full iOS build require macOS CI and have not been observed, in accordance with the user's request to report the build result themselves.

Graphify was used before source exploration and refreshed after edits. Work stayed on main and preserved unrelated VPN, vendor, audit and graph setup files. No subagents were used.
