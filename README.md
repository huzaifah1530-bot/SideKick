# SideKick

SideKick is a native SwiftUI iOS sideloading app. The existing SwiftUI screens and IPA library are being integrated with SideStore's on-device signing and installation engine.

## Integration status

- The SideStore source is pinned as a recursive Git submodule at `Vendor/SideStore`.
- The build uses SideStore's Xcode project and runtime bootstrap, while the app scene presents SideKick's SwiftUI UI.
- The IPA library imports IPA files from Files, validates their bundle metadata, stores them locally, supports search, and removes imported files.
- Apple ID sign-in, account selection per app, IPA install, pairing setup, LocalDevVPN readiness, and refresh are not yet wired into SideKick's screens. Do not treat these as working until they pass on a physical device.

Free-account builds require the shared App Group to be present in the installed app's provisioning/signing state. A successful unsigned CI build does not verify that requirement. Initial SideStore-style installation and pairing also require the external computer/iLoader setup; LocalDevVPN is a separate app that must be installed and connected by the user.

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
