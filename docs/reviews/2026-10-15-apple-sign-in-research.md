# Apple sign-in investigation — 15 October 2026

Research only. Three GPT-6.1 Sol agents using low reasoning independently checked upstream changes, alternate fixes, and SideKick compatibility. No app code changed or Apple account login attempted.

## Findings

There are multiple failures, not a single universal sideloading outage. The Anisette maintainer identifies device identity inconsistent with the Android library generating authentication data as a cause of the October rejection. This is a maintainer diagnosis, not a published Apple explanation. Merely changing between servers using the same implementation may leave it unchanged. [Maintainer discussion](https://github.com/Dadoum/anisette-v3-server/issues/61)

Apple also changed trusted-device two-factor responses. SideSign's merged October 13 fix recognizes `hsc=409` without `au`, allowing entry of an already-pushed code. In this scenario a code arriving alongside `-22411` can reflect missing challenge handling; the error alone does not establish throttling. [Official SideSign PR #5](https://github.com/SideStore/SideSign/pull/5)

The Reddit patch exists. Its first PR, #1659, was closed by its author; replacement **#1660 is open and unmerged** when checked. It changes Anisette selection, migrates legacy headers, adds ADI recovery and pairing detection changes. Its claims of fixing every affected login are not established by review or device testing here. [Current PR](https://github.com/SideStore/SideStore/pull/1660), [Reddit announcement](https://www.reddit.com/r/SideStore/comments/1x6qygh/fix_sidestore_apple_id_signin_80045_503_pairing/)

The fork publishes experimental build `0.7.0-20261015.5+5aef228c`. It is distinct from an official SideStore release. [Fork release](https://github.com/raj-sh-git/SideStore/releases)

Its latest SideSign changes use Windows client-info and align the authentication User-Agent with Anisette data. Earlier Android/Pixel advice describes an earlier workaround, not the current fork defaults. [Header commit](https://github.com/raj-sh-git/SideSign/commit/f4e8df8bd979cba11ddf7c4898e2a5d03ae00dab)

Recovery code reprovisions once on `-45061` and implements remote SIM resynchronization. App-level clearing also matches `-80045`; that code does not prove every such failure represents a corrupt ADI blob. Broad error/header string matching needs review before adoption. [Recovery implementation](https://github.com/raj-sh-git/SideSign/commit/6bd4d9b0ae21b45a8ef68411b558e3ff59db5dae)

Official iLoader **2.3.8** explicitly addresses 503 and automatically changes supported servers. Its notes say fresh authentication is required, trusted-device 2FA works, and SMS remains broken. Updating the computer installer does not update authentication inside an already-installed SideKick or LiveContainer bundle. Success on a particular account/device is still unverified here. [Official release](https://github.com/nab138/iloader/releases/tag/v2.3.8)

## SideKick gaps confirmed locally

- `SideKick/Services/SigningAccountStore.swift` uses the vendored AuthManager and preserves Anisette on sign-out. Removing an account therefore does not regenerate ADI.
- Vendored SideSign revision `6b68651697f99791ef85404b7aea1891a26a285d` lacks the merged pushed-code handling. `Sources/DeveloperPortal/Authentication.swift` dispatches challenges through `au` and throws nonzero errors before handling the newer challenge.
- `SideKick/Views/Settings/SideStoreSettingsPages.swift` exposes Anisette modes/servers but no dedicated recovery action. Header reset is different from ADI reset.
- Existing audit patches modify authentication logging. Any compatibility backport must preserve redaction and reproducible CI patch application.
- SideKick can address this in its own authentication dependency; changing LiveContainer source is unnecessary. An independently bundled SideStore would need its own updated build.

## Proposed implementation tasks

1. **Protocol and identity:** backport official pushed-2FA handling; review compatible Windows provider selection and matching headers. Preserve intentional user configuration and existing audit patches. Do not adopt the entire experimental fork or unrelated pairing fallback blindly.
2. **Recovery:** serialize a narrowly scoped ADI/cache reset and bounded retry for recognized provisioning failures. Preserve accounts, certificates and app records. Provide an explicit settings recovery action with clear outcome messages.
3. **Verification:** fixtures for pushed 2FA, actual credential errors, malformed responses, 503, cancellation, retry limits and provider transitions. Then test trusted-device sign-in and refresh on iOS with existing/fresh ADI. Linux tests and an IPA build cannot establish successful Apple authentication.

Disabling on-device Anisette or resetting ADI alone is conditional troubleshooting. A complete fix must address both compatible Anisette identity and the current authentication response flow.
