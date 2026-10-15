# Authentication, lifecycle and diagnostics follow-up

Scope: user request of 15 October; implement in this session without delegation, commits or publication. Preserve existing dirty files and vendor pins.

1. Compare 0.6.4, 0.7.0-alpha and nightly SideSign changes against the shipping patch chain. Preserve cryptographic proof checks and nonzero Apple errors. Add regression cases for empty `au` and consistent provider identity through two-factor requests. Do not infer the device's Apple error from its generic alert.
2. Use UIKit application lifecycle in the hosted root. Resume must schedule pending discovery; background still cancels and invalidates results. Keep throttling, per-target generation checks and newest-download short circuit.
3. Add one bounded, protected structured diagnostic store with typed stages, operation IDs, entry points and numeric error/HTTP codes. Bridge typed SideSign events without forwarding arbitrary logging text, headers, bodies or URLs. Instrument authentication/Anisette/team/session, signing, installation, refresh, connection and GitHub. Add Settings view/share/clear.
4. Test persistence, hostile errors, numeric codes, export, clearing, patch composition and lifecycle integration. Run available portable checks. Swift/iOS runtime checks require an Apple toolchain; report unavailable checks explicitly. Review diffs and refresh Graphify.

Review focus: no blanket -22411 bypass; no retry of rate limits; preserve saved account/certificate data; cancellation must not publish stale results; no secret-bearing text in shared diagnostics or exports. Device authentication and automatic discovery remain unverified until device follow-up.
