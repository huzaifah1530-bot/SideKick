# SideKick iOS interface audit — 16 October 2026

## Scope and method

Reviewed the shipped `SideKick/` SwiftUI root, setup, app library, app management, updates, accounts, LiveContainer entry, shared rows, and settings. Used the two supplied SideStore screenshots as direction for a scannable app library, while keeping SideKick's blue and violet identity. Priorities use the Frontend Design Audit scale (0–4) and are based on repeated user impact. This is a source-based audit: the current Windows host has no Xcode or iOS Simulator, so visual, VoiceOver, and device interaction checks remain open.

## Prioritized findings

| Severity | Finding and principle | Effect | Change |
| --- | --- | --- | --- |
| 3 | Seven setup pages front-load optional notification, background, and shortcut decisions (structure, minimalist design, user control). | A first-time user must make peripheral choices before seeing the app. | Four focused setup steps. Permissions and shortcut controls remain in Settings. |
| 3 | Settings mixes common tasks with ports, logs, tokens, and diagnostics; connection appears twice (structure, recognition, consistency). | Users must scan a long technical list to find routine controls. | Grouped everyday controls on the first screen; technical controls under Advanced. |
| 3 | Empty app and account screens explain the state without a direct next action (affordances, achievement). | New users must discover the toolbar plus button. | Added clear import and account buttons to native empty states. |
| 3 | An app with no account only says to visit Accounts (error recovery, user control). | The install path reaches a dead end. | Added a direct account destination and kept its navigation inside the current stack. |
| 2 | An empty Updates destination sits above the app library (hierarchy, minimalist design). | It displaces the content most people came to manage. | Show the Updates row when a source, queue, or configuration error exists. |
| 2 | The Updates screen repeats a check action in its status list (consistency, hierarchy). | A routine page action looks like content. | Moved Check for Updates to the native toolbar; pull to refresh still works. |
| 2 | Bright fixed-width expiry pills dominate every app row (hierarchy, perceptibility, accessibility). | Names compete with repeated green badges and text has little room to grow. | Replaced pills with plain signing status under the version; urgent status uses text and color. |
| 2 | Active, offloaded, imported, and LiveContainer rows use different icon sizes and layouts (consistency). | The library feels assembled from separate features. | Reused one native row presentation for installed, inactive, and imported apps. |
| 2 | App links suppress the system disclosure indicator on newer iOS versions (affordances). | Rows look less obviously navigable. | Restored native link indicators across the library. |
| 2 | The first tab is labeled with the brand while its screen title says “My Apps” (match, navigation). | The destination is less predictable than its content. | Labeled the tab “Apps.” |

## Design direction

- Keep the three existing destinations: Apps, Accounts, Settings. Each has a distinct job; moving Accounts into Settings would bury a required signing workflow.
- Use system `TabView`, `NavigationStack`, grouped lists, buttons, sheets, and typography so navigation receives the current iOS appearance automatically. Liquid Glass belongs in the system control layer, not on every app row.
- Build the shipping integration with the Xcode 27 runner so the app uses the iOS 27 SDK and its native control appearance.
- Let app icons and names lead. Keep SideKick blue as the interaction accent, reserve orange for urgent signing state, and use semantic system backgrounds and secondary text for the content layer.
- Keep advanced device and GitHub controls available through progressive disclosure. No functional destination was removed.

## Verification needed on an Apple host

1. Build the shipping SideStore integration with the current Xcode and an iOS 27 simulator.
2. Inspect setup, empty and populated Apps, Accounts, Settings, Advanced, app detail, and Updates in light/dark appearance and larger Dynamic Type sizes.
3. Check VoiceOver reading order, button labels, sheet dismissal, tab state, and the account recovery link from an imported app.
