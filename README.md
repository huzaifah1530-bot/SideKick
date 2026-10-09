# SideKick

SideKick is a native SwiftUI iOS app for managing sideloaded IPA files.

## Current functionality

- Import an IPA from Files.
- Validate that it is an iOS app archive and read its bundle ID, name, and version from `Info.plist`.
- Keep imported IPA files and the library index in the app's Application Support directory.
- Search the library and remove imported files.

Signing, installation, Apple ID authentication, pairing, and app refresh are not implemented yet. The app labels these capabilities as unavailable; it does not simulate installs or refreshes.

## SideStore backend research

SideStore's on-device install path is a full application engine. It includes Apple developer account authentication, certificate and provisioning profile management, IPA signing, a database and install pipeline, device pairing, Minimuxer, and EM Proxy. The in-device install flow also relies on the LocalDevVPN companion and its system-granted entitlement. SideKick's current `IPAImportStore` is only the file and metadata layer, not that signing/install engine.

SideStore is licensed under AGPL-3.0. Incorporating its engine into a distributed SideKick build has source-distribution obligations. Review that license before vendoring or adapting its code.

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

The repository uses XcodeGen and GitHub Actions to build an unsigned iOS IPA. See `.github/workflows/ios-build.yml`. The IPA must be signed and provisioned before it can be installed on a device.

## Design references

- [Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/)
- [Apple Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/liquid-glass)
- [SideStore](https://github.com/SideStore/SideStore)
