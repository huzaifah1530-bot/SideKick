# SideKick

SideKick is a native SwiftUI iOS sideloading companion. It is designed around the App Store’s clarity and the current iOS Liquid Glass material: install IPA files from the Files picker, monitor signing windows, refresh installed apps, and switch between Apple ID signing profiles.

## Project structure

```text
SideKick/
├── App/              App entry point and shared environment
├── Components/       Reusable native SwiftUI components
├── DesignSystem/     Color, typography, spacing, and glass helpers
├── Models/           Sideloaded apps and Apple ID domain models
├── Services/         Signing/install protocol and demo implementation
├── ViewModels/       Screen state and orchestration
├── Views/            Feature screens and root navigation
└── Brand/            SideKick icon source and asset notes
```

## Important implementation boundary

The UI is ready for a real SideStore-compatible signing service, but `DemoSideloadingService` intentionally does not perform signing or installation. A production service should be injected behind `SideloadingService` and own pairing, certificate creation, provisioning profile handling, IPA signing, installation, and refresh scheduling. Keep Apple ID credentials in Keychain; never persist passwords in `UserDefaults` or app storage.

## Design references

- [Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/)
- [Apple Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/liquid-glass)
- [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
- [SideStore](https://github.com/SideStore/SideStore)

The included icon source in `Brand/SideKickIcon.svg` is a layered starting point for an Xcode Icon Composer document. Export the final light/dark/tinted variants into `Assets.xcassets/AppIcon.appiconset` before shipping.

`project.yml` is an XcodeGen project definition so the folder structure can be regenerated as a native `.xcodeproj` on macOS with the current Xcode toolchain.
