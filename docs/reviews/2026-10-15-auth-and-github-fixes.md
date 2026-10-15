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
