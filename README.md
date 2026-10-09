# SideKick

SideKick is a native SwiftUI iOS sideloading app. The existing SwiftUI screens and IPA library are being integrated with SideStore's on-device signing and installation engine.

## Integration status

- The SideStore source is pinned as a recursive Git submodule at `Vendor/SideStore`.
- The build uses SideStore's Xcode project and runtime bootstrap, while the app scene presents SideKick's SwiftUI UI.
- The IPA library imports IPA files from Files, validates their bundle metadata, stores them locally, supports search, and removes imported files.
- Apple ID sign-in is connected to SideStore's native authentication flow. SideKick stores each account/team session and its signing certificate separately in the iOS Keychain and can switch the active SideStore identity.
- IPA install and account-scoped refresh are routed through the integrated signing engine; these still need physical-device validation. SideKick now exposes pairing-file import and connection validation in Settings.
- A pairing file must first be created on a computer paired with the iPhone. SideKick does not create that trust record on-device. SideStore's app is not required.
- Install and refresh currently require Wi-Fi and the separate LocalDevVPN App Store app. This SideKick build has neither the Network Extension entitlement nor a tunnel extension, so it cannot enable that VPN itself. Settings links to LocalDevVPN and explains the setup.

SideKick stores its database in private app storage and does not require SideStore's App Group or app. The unsigned CI build still does not verify signing or on-device functionality. Pairing-file creation requires a previously paired computer. The current install/refresh transport requires LocalDevVPN; it is not bundled in SideKick.

The upstream SideStore scheme also builds a widget extension. SideKick removes that extension from the packaged IPA because it is not part of the standalone app and an unsigned extension cannot be installed without its own valid provisioning profile.

## Build and source distribution

GitHub Actions recursively checks out the pinned SideStore source and builds the integrated target. Each build uploads an unsigned IPA and a matching `SideKick-corresponding-source.tar.gz` artifact. Distribute those together, and keep source access available to anyone who receives the IPA.

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

The canonical build is the GitHub Actions workflow in `.github/workflows/ios-build.yml`. Check out with `git clone --recurse-submodules` for local work. The workflow currently produces an unsigned iOS IPA; it does not sign the app for your device or prove on-device functionality.

## Design references

- [Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/)
- [Apple Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/liquid-glass)
- [SideStore](https://github.com/SideStore/SideStore)
