# Authentication compatibility, custom Anisette and GitHub diagnostics

## Apple authentication

Backports the merged SideSign pushed-code flow for `hsc=409` without `au`, presenting the verification entry without sending a redundant code and bounding repeated pushed challenges. Actual credential errors remain errors. Authentication requests use the provider's User-Agent. Existing audit logging redaction and provider synchronization remain in place.

A narrowly recognized remote `-45061` provisioning failure retries once without the stale blob. Settings can explicitly regenerate provisioning and clear both provider caches while keeping saved accounts, certificates and app records. Settings mutations share the signing gate and reject active app operations.

Settings → Anisette supports a custom HTTPS server (HTTP only on localhost), client information, and User-Agent. Control characters/header injection are rejected. The Windows preset sets its server and matching headers together; on-device defaults remain separate. Saving a changed provider or identity resets incompatible provisioning. Existing explicit custom choices are preserved during bootstrap. Existing users can choose the Windows preset and save before retrying sign-in.

Patches apply after the existing vendor audit patches in CI. The broad experimental fork's SIM resynchronization, pairing fallback and dependency replacement are outside this fix. Actual Apple login still needs device verification; a successful build does not establish account authentication success.

## GitHub update discovery

The regression reproduced a latest valid build being discarded because a request for an older Actions run returned HTTP 503. The shared discovery flow now stops at the latest matching downloadable build. Its cache is partitioned from full version history, so shortened discovery cannot truncate the versions list. Existing throttled launch checks and forced pull-to-refresh still use the app-owned scan and source/target publication guards.

No evidence established a prohibition on parallel requests or a difference between automatic and detail token lookup. The concurrency bound remains three. Diagnostic events now expose scheduling, per-app checks, token presence, HTTP status, cancellation, stale results and whether a result reached app state.

Settings → GitHub Update Logs displays recent activity, supports sharing and clearing, and retains at most 250 events across launches. Structured events omit credentials, headers, raw errors and response bodies; repository URLs discard user information, query strings and fragments. Repository and app names are visible when explicitly sharing the log.

## Verification

- Portable Swift tests cover the older-run regression, independent history cache, custom settings validation/preference preservation and bounded/redacted diagnostic persistence.
- The authentication regression applies the actual audit/compatibility patch chain in an isolated checkout, parses patched Swift and compiles/runs a Swift 6 behavioral fixture.
- The full macOS CI build verifies UIKit/SwiftUI integration and the shipping patch order. Device follow-up should exercise existing/fresh provisioning, trusted-device verification, launch discovery, pull-to-refresh and update log sharing.

## Follow-up after device failure (15 October 2026)

The earlier build did **not** fix device authentication or establish automatic update discovery. The supplied Apple alert contains no Apple code or stage. The two GitHub screenshots show repeated `suspended` deferrals and unchecked targets; these are scheduling evidence, not HTTP failures.

### Upstream comparison

| Source | Evidence and comparison |
| --- | --- |
| [0.6.4](https://github.com/SideStore/SideStore/releases/tag/0.6.4) | Marked DO NOT USE due to sign-in regression. |
| [0.7.0-alpha](https://github.com/SideStore/SideStore/releases/tag/0.7.0-alpha) | September release addresses Apple's 503 sign-in change. [d7565c9f](https://github.com/SideStore/SideStore/commit/d7565c9f) changes the Anisette client from Xcode to akd; subsequent commits expose client configuration. These changes already exist in Sidekick's pinned SideStore tree. The release commit `6032424a` itself updates minimuxer; it is not the entire authentication fix. |
| [Nightly 12ff39c6](https://github.com/SideStore/SideStore/commit/12ff39c6b6c0ccd8180f0834a893a4bbaf7bcd31) | October 13 update changes SideSign `6b686516` → `752d1ef6`, incorporating merged [SideSign #5](https://github.com/SideStore/SideSign/pull/5). Sidekick pins the older SideSign but already backports its pushed-code selection, prompt and bounded recursion. |
| [Issue #1652](https://github.com/SideStore/SideStore/issues/1652) | Community discussion separates identity-related HTML 503s, Apple `-80045` rejections and the `hsc=409`/missing-`au` challenge. Reports include failures even with the nightly. Account/IP explanations are hypotheses, not confirmed Apple diagnoses. |
| [SideStore #1660](https://github.com/SideStore/SideStore/pull/1660) | Still open and unmerged when checked. Its broader workaround is not an upstream-confirmed universal repair; SIM/pairing/dependency rewrites were not imported. |
| [AltSign #59](https://github.com/rileytestut/AltSign/pull/59/files) | Open proposal handles both empty and missing `au`, and refreshes Anisette between later stages. This is corroborating implementation evidence, not a merged SideStore guarantee. Fresh-OTP changes require a separate provider/callback design and device evidence; not copied wholesale here. |

Read-only `/v3/client_info` checks on `win.ani.sidestore.io` and `ani.jkcoxson.com` both returned the existing Windows preset's exact client-info and User-Agent. This validates the preset identity on these endpoints at investigation time, not Apple account acceptance.

### Decisions and changes

- Preserve the nonzero Apple error gate, including `-22411` and `-80045`. A possible early rejection of a challenge is a hypothesis until actual safe response metadata is captured. Never accept an arbitrary error as successful authentication or bypass SRP server-proof validation. The new logs retain HTTP status, Apple `ec` and `hsc` separately so a future fix can be based on the actual response.
- Treat empty `au` like absent `au`; explicit nonempty authentication types retain precedence. Two-factor requests now use the same provider User-Agent policy as the initial authentication request. This closes a concrete inconsistency in the previous implementation. HTTP 429 is classified as too many attempts without automatic retries. The existing one-time remote provisioning recovery remains restricted to `-45061` with an existing blob.
- The shipping app is a UIKit app with `UIHostingController(ContentView())`, installed by `sidestore-sidekick.patch`. `SideKickApp.swift` is excluded from the product. The hosted root relied on SwiftUI `scenePhase`, which can retain its background default; `pauseGitHubChecks` then blocks shared discovery, while individual detail checks bypass that flag. Foreground resume also only cleared the flag without scheduling work. The root now samples `UIApplication.applicationState` at startup and observes UIKit foreground/background notifications. Resume immediately requests pending work; background cancellation/generation invalidation and the 15-minute throttle remain. Device confirmation is still required for the screenshot's exact lifecycle sequence.
- Preserve the latest-download short circuit and separate history cache. No changes to `GitHubUpdateDiscovery` or `GitHubHistoryStore` were needed.
- Add Settings → Diagnostics and a Diagnostics button on the Apple-ID failure alert. One bounded store covers Apple sign-in, Anisette, two-factor responses, team selection, session storage/restoration, signing preparation, installation, refresh, local connection and GitHub/lifecycle summaries. Install/refresh/signing stages share an operation ID; GitHub scan tasks propagate their scan ID to child tasks. Detailed GitHub logs remain accessible separately.
- Library events cross a typed notification bridge; ordinary vendor console text is never copied. Stages/events/entry points are allowlisted; error information consists of numeric codes and bounded numeric underlying-error chains. No passwords, verification codes, tokens, account identifiers, keys, blobs, URLs, headers or response bodies enter the shared store. Persistence is limited to 500 entries/1 MB on load, uses iOS file protection, excludes the file from backup, supports export/clear and reports persistence failure. Tests exercise hostile error domains, descriptions and failing URLs, persistence, clearing and correlation.
- Shipping patches are applied after the existing audit patches, with a small `sidestore-diagnostics.patch` for Anisette/team stages. No vendor pin or checked-out vendor source was changed. The local VPN file receives only diagnostic wrappers in this commit; its pre-existing connection-behavior edits remain unstaged.

### Verification and next device check

Local Windows verification: five release/integration/lifecycle Python tests and the authentication patch-composition fixture pass. Lifecycle checks are source integration contracts, not UIKit runtime simulations. The auth fixture still rejects every nonzero Apple code and compiles its actual extracted response gate when Swift is available. New portable Swift tests cover diagnostic persistence/export, secret exclusion, underlying numeric codes and operation correlation. Swift and Xcode are unavailable on this host, so Swift execution and the iOS build are delegated to the existing GitHub Actions workflow after the user-authorized push. The previous build's 61 passing tests do not validate these new changes.

Verified CI result: implementation commit `e9812603259d2ef6d7ef174e8805cb1108b25091` was pushed with user authorization. [Actions build 116](https://github.com/huzaifah1530-bot/SideKick/actions/runs/38799116661) completed successfully: **64 portable Swift tests**, the compiled Swift 6 authentication fixture, release/integration/vendor regressions, full iOS compilation, IPA packaging and manifest validation. Uploaded artifacts include `SideKick-unsigned-ipa`, `SideKick-vpn-unsigned-ipa`, the release manifest and corresponding source. This is compilation/fixture evidence only; device authentication and automatic discovery remain unverified.

Additional architectural check: SideSign's `Compatibility.swift` aliases `ALTAppleAPI` to `DeveloperPortal` and `ALTAnisetteData` to `AnisetteData`. `DeveloperPortalProxyWithAuth.signIn` therefore reaches the patched SideSign authentication implementation, rather than a separate legacy authentication engine.

On the next device build: try adding an Apple ID once, then open Diagnostics directly from the failure alert and share that operation. Inspect the last successful stage and `ec`/`hsc`/HTTP values before choosing another authentication change. Test launch, background/resume, manual Updates refresh and opening a detail page; the shared scan should start and publish per-app results instead of remaining suspended. Verify diagnostic sharing and clearing. **No successful device authentication or automatic discovery result has been observed in this follow-up.**

Graphify is a navigation aid over the checked-out tree; CI patches are not represented as applied vendor AST. Consult the workflow and patch-composition fixtures for the shipping code. The graph is refreshed locally after edits; the pre-existing untracked Graphify setup is not included in this task's commit.
