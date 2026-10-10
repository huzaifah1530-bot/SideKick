# SideKick

SideKick is a native SwiftUI iOS sideloading app. The existing SwiftUI screens and IPA library are being integrated with SideStore's on-device signing and installation engine.

The deployment target is iOS 18. Native controls use the system appearance; custom Liquid Glass effects and hidden navigation indicators are gated to iOS 26, with regular material and standard disclosure indicators on iOS 18. These compatibility paths still need device validation.

## SideStore credit and derived components

SideKick builds on [SideStore](https://github.com/SideStore/SideStore), an open-source sideloading project. The pinned upstream source is included as the recursive Git submodule `Vendor/SideStore`; SideStore is licensed under AGPL-3.0. SideKick also uses upstream SideStore dependencies, including Minimuxer and SideSign. Their notices and distribution notes are in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

The integrated app derives its sideloading engine from SideStore. Specifically, the build compiles SideStore's `SideStore` app target and uses its app bootstrap, Apple account authentication, Developer Portal access, signing certificates and provisioning profiles, pairing and Anisette support, and install and refresh operation pipelines. SideKick's `SigningAccountStore` and `SideStoreOperationService` call and adapt those upstream APIs for SideKick's account and install flows. The CI workflow applies the integration patches in `patches/` to the pinned upstream checkout.

SideKick's app experience is implemented in this repository's `SideKick/` directory: its SwiftUI navigation and screens, visual design, IPA library and local storage, GitHub release and artifact update tracking, update queue, and notifications. The integration patch changes SideStore's launch scene to show SideKick's `ContentView`; it does not replace SideStore's underlying signing engine. Some SideKick settings expose or configure SideStore capabilities, while their presentation is built in SideKick.

## LocalDevVPN credit and derived components

SideKick uses code from [LocalDevVPN by seomin0610](https://github.com/seomin0610/LocalDevVPN), originally forked from jkcoxson/LocalDevVPN, with contributions credited to Stossy11, Magesh K, and the SideStore Team. The imported tunnel provider, CIDR validation, and tunnel constants are pinned to commit `8a97427bcbdf90cbb62c2eadb8cfe5751c50eccc` in `SideKickVPN/`. SideKick adds packet-loop shutdown, a heartbeat watchdog, a native extension target, operation-scoped connection management, and its own setup/settings UI. The original [StosVPN license](SideKickVPN/LICENSE) and [provenance](SideKickVPN/UPSTREAM.md) are included; CI bundles the license with the app.

## Integration status

- **LiveContainer:** My Apps has a separate guest library with bookmarked read-only directory scanning, version/build metadata, connection recovery, launch requests, and existing GitHub source/token/update notifications. Link an actual Applications directory exposed in Files. Private App Group access is not assumed; snapshots are labelled and excluded from automatic checks/guest launches. Guest IPAs never enter SideKick's signing/install queue. See [integration behavior and validation limits](docs/livecontainer-integration.md).
- Storage offers **Manage Cached & Temporary Files** with ownership explanations and explicit retained-source removal. Deleting a current extracted source can require reimporting an IPA before refresh. Recent/current-process temporary files are protected. Update options show all saved accounts: another team requires a separate source-based installation with separate data/credentials.
- GitHub installed-build selection preserves manual overrides and saved baselines absent from the current history page; suggestions are optional. The root `swift test` suite verifies the production scanner, stores, build comparison, and filesystem boundaries before the integrated CI build.

- The SideStore source is pinned as a recursive Git submodule at `Vendor/SideStore`.
- The build uses SideStore's Xcode project and runtime bootstrap, while the app scene presents SideKick's SwiftUI UI.
- The IPA library validates bundle metadata, keeps links to originals selected from Files, and stores downloaded GitHub IPA copies locally. Removing a linked library entry keeps the original in Files.
- When an imported IPA matches an installed app, choosing **Queue for Update** marks it as a pending update. It appears in the Home screen’s **Updates** section, and the installed app’s detail page offers **Update** instead of **Open** until the queued IPA is installed or removed. URL imports use the same flow.
- **Import from URL** accepts GitHub repository links as well as direct IPA links. Browse release IPAs or choose an Actions workflow and branch, load more downloads, then review and download with progress and cancellation. After successful installation, the selected release/build becomes the update baseline automatically. Version numbers in release asset filenames use a wildcard filter so later releases can still match.
- **Settings → GitHub Tokens** supports multiple named tokens, editing/replacement, deletion, and a default token. Each app’s **GitHub Update Source** can override that default, and GitHub download pages offer a token picker. Existing single-token installations migrate automatically; tokens and their labels stay in iOS Keychain. Removing a token explicitly selected by an app requires choosing another token for that app.
- GitHub update sources use release or workflow-artifact history to track new builds. During setup, choose the version already installed; SideKick can suggest one from the original IPA’s file date, so connecting a repository does not require reinstalling the app.
- Setup uses scrollable pages, consistent spacing, fixed navigation, loading indicators, optional notification/background permissions and a persisted completion state.
- Download progress comes from the session download delegate; unknown-size transfers display bytes and activity instead of a frozen 0%. Token selection and token management have separate pages.
- Apple ID sign-in is connected to SideStore's native authentication flow. SideKick stores each account/team session and its signing certificate separately in the iOS Keychain and can switch the active SideStore identity.
- IPA install and account-scoped refresh are routed through the integrated signing engine; these still need physical-device validation. SideKick now exposes pairing-file import and connection validation in Settings.
- Settings includes dedicated pages for app refresh, install/signing behavior, connection and pairing, Anisette, and imported-IPA storage. Developer Portal App IDs, profiles, and certificates are managed from each Apple ID in Accounts.
- App details place Open/Update and Refresh in separate groups above Details. Each relevant Options row uses a full-size icon and label. GitHub sources, sharing, re-signing, and JIT live together under App Settings.
- Expiry badges and Details use the same remaining-day calculation and reload on foreground opening. Partial days count toward the next day; the detail page also shows the exact expiry time.
- A missing GitHub download can be downloaded again. Update options allow skipping one build or marking an exact build as already installed; future builds remain eligible. Identical app version names do not establish that two Actions builds are the same.
- A pairing file must first be created on a computer paired with the iPhone. SideKick does not create that trust record on-device. SideStore's app is not required.
- **Standard IPA:** free and paid accounts use LocalDevVPN from the App Store. Setup offers a connect button and device verification. SideKick cannot disconnect another app’s VPN; scheduled refreshes require that local tunnel to be connected beforehand.
- **Optional built-in VPN IPA:** embeds the local packet-tunnel extension derived from [LocalDevVPN](https://github.com/seomin0610/LocalDevVPN). Choose it under Settings → Local Connection → Connection Method when both signed profiles support Network Extensions. It connects for device operations and disconnects afterward, with a 90-second watchdog. External LocalDevVPN remains the default connection method.

SideKick stores its database in private app storage and does not require SideStore's App Group or app. The unsigned CI build still does not verify signing or on-device functionality. Pairing-file creation requires a previously paired computer. The standard build does not include a VPN extension or request VPN entitlements, so free Apple IDs remain supported through LocalDevVPN. The optional built-in VPN build requires Network Extension packet-tunnel-provider permission in both app and extension profiles; free Apple ID provisioning cannot supply that permission. Free-account in-app signing removes the optional tunnel extension if a user imports that build.

Database storage stays at `Library/Application Support/SideKick` when signing entitlements change. If an older App Group database is accessible and no private database exists, SideKick copies it and its related files before opening the private database. An already inaccessible App Group or a different iOS app container cannot be recovered by this migration. Installed records remain visible when their signing account needs reconnecting. Account/team names are also stored in a non-secret catalogue. SideKick can recover known database account/team records and enumerate its own saved Keychain sessions after a migration; temporary read errors no longer clear the account list. Reconnect is available from Accounts. Legacy startup maintenance no longer signs out or wipes active credentials on updates. Keeping the same bundle identifier, signing team and app container is required to preserve access: a different team, deleting the app, or replacing it as a different app cannot transfer protected Keychain sessions automatically.

GitHub checks run when My Apps opens or refreshes, on every **Refresh SideKick Apps** shortcut run, and in the integrated background refresh callback. Shortcut checks run even when apps were already refreshed today or the local VPN cannot connect. New builds trigger local notifications; repeated checks do not repeat a dismissed notification for the same build. There is no always-running monitor: iOS controls background execution, and notifications require permission. Expiry reminders are scheduled ahead of time.

Storage retains the source bundle required to re-sign each managed app. Successful, failed, and cancelled pipelines clean up their staged app and IPA files. On startup, SideKick removes pipeline/import files left by previous processes and unreferenced managed IPA copies. Storage settings measure all private Documents & Data, including hidden files, Library databases/preferences, URL caches, diagnostic logs, all temporary files, and accessible legacy App Group data. Folder pages show where space is used. Console logs retain at most 5 MiB for the active file plus 10 MiB of older logs. **Clean Unused Files** also clears cached network responses; it keeps app records and user exports. iOS Storage can update later and account for allocated/shared space differently.

The ported settings and their runtime connections are documented in [`docs/settings-functionality.md`](docs/settings-functionality.md). Code tracing and local checks do not replace physical-device validation.

The upstream SideStore scheme also builds a widget extension. SideKick removes that extension from the packaged IPA because it is not part of the standalone app and an unsigned extension cannot be installed without its own valid provisioning profile.

## Build and source distribution

GitHub Actions recursively checks out the pinned SideStore source and builds the integrated target. Each build uploads the standard `SideKick-unsigned-ipa` artifact (`SideKick-unsigned.ipa`), an optional `SideKick-vpn-unsigned-ipa` artifact (`SideKick-vpn-unsigned.ipa`) for eligible profiles, and a matching `SideKick-corresponding-source.tar.gz` artifact. Distribute those together, and keep source access available to anyone who receives the IPA.

SideStore and Minimuxer are AGPL-3.0; SideSign is identified upstream as GPL-3.0. See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md). A license file is absent from the pinned SideSign checkout, and the transitive package license set still needs a final audit before distributing builds beyond this private project. The corresponding-source artifact is intended to accompany each IPA.

## Project layout

```text
SideKick/
├── App/              App entry point and shared environment
├── Assets.xcassets/  App icon
├── Brand/            Layered icon source
├── Components/       Reusable SwiftUI components
├── DesignSystem/     Colors and Liquid Glass helpers
├── Models/           Imported IPA metadata
├── Services/         IPA archive parsing and local persistence
├── ViewModels/       Screen state and orchestration
└── Views/            Today, Library, Accounts, and Settings screens
```

## Build

The canonical build is the GitHub Actions workflow in `.github/workflows/ios-build.yml`. Check out with `git clone --recurse-submodules` for local work. The workflow builds without provisioning and adds ad-hoc signatures to preserve Network Extension entitlement requests for re-signers. This is still not a device-signed or installable IPA: an eligible signer must provision both the app and extension. A CI build does not prove on-device functionality.

## Design references

- [Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/)
- [Apple Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/liquid-glass)
- [SideStore](https://github.com/SideStore/SideStore)
