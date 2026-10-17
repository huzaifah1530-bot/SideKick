# SideKick UI/UX audit and Liquid Glass redesign plan — 17 October 2026

Status: **audit and plan only. No source has been changed.** Builds on `2026-10-17-frontend-visual-audit.md` (whose fixes are already in source) and goes further: structural simplification, not polish.

## Evidence and limits

- **Source:** I located the files with `graphify query` and then read the SwiftUI views directly. Two read-only sub-audits covered the remaining views. Files I only grep-scanned are marked *(partial)* in the inventory.
- **Screenshots:** the 19 dark-mode device captures you attached. S-numbers follow attachment order:
  - S1 Apple ID
  - S2 Apollo status
  - S3–S4 My Apps
  - S5–S9 Re-sign and Restore Status
  - S10–S11 App Update
  - S12 SideKick status
  - S13–S14 Settings
  - S15 Accounts
  - S16 GitHub Updates settings
  - S17–S18 LiveContainer app detail
- **Inspiration:** Blank Street, Plasma and Onyx. What I take from them:
  - one focal headline per screen
  - a segmented progress tracker
  - a single bottom primary action
  - icon-led rows inside one soft container
  - lots of whitespace
- **Not verified:** nothing has been compiled or rendered. This Windows workspace has no Xcode or Simulator. CI uses Xcode 26 with an iOS 18 deployment target, so iOS 26 Liquid Glass APIs are available behind `#available(iOS 26, *)` and need iOS 18 fallbacks. Light mode, Dynamic Type and VoiceOver were not observed in any capture.

### On the attached `premium-design` skill

I've applied its principles: restraint, one accent, typography as hierarchy, scale contrast, whitespace over boxes, and intentional motion. Three of its rules conflict with your brief and Apple's HIG, so I'm deliberately **not** following them:

| Skill rule | Why it's set aside |
| --- | --- |
| "Never use system fonts" and serif display faces | Native iOS apps should use SF Pro and Dynamic Type. Custom display fonts break accessibility scaling and the Apple-native goal. |
| "No teal" | You explicitly asked for a green-blue/teal brand colour. |
| 800–1800 ms reveals and scroll-driven motion | iOS motion should be system springs, around 0.3–0.5 s, and must respect Reduce Motion. |

The skill targets editorial websites. Its catalogue (`references/…`) isn't present in this workspace.

---

## 1. UI inventory

### Root and shell

| Screen | File | Reached by |
| --- | --- | --- |
| Database loading/failure | `Views/Root/ContentView.swift:111` | App launch |
| Required setup (4 steps) | `Views/Root/RequiredSetupView.swift:166` | Setup not ready |
| Tab bar: Apps / Accounts / Settings | `ContentView.swift:17-30` (legacy `.tabItem`) | Root |
| Global "Save changes?" alert | `ContentView.swift:47` | Unsaved settings guard |

### Apps tab

| Screen | File |
| --- | --- |
| My Apps (Updates row; Installed, Inactive, LiveContainer and Ready to Install sections) | `Views/Home/HomeView.swift:103` |
| Refresh Results sheet | `HomeView.swift:648` |
| Import from URL | `Views/Home/IPASharingViews.swift:93` |
| Share IPA | `IPASharingViews.swift:4` |
| App detail (`AppManagementView`, 3 initialisers) | `Views/Library/AppManagementView.swift:5` |
| **OperationStatusView**: Refresh, Re-sign, Install, Update, Offload and Restore Status | `AppManagementView.swift:579` |
| Install confirmation ("Ready to Install") | `AppManagementView.swift:1107` |
| Re-sign App / Refresh Options / Choose Account (three near-identical account pickers) | `AppManagementView.swift:804, 865, 1009` |
| Enable JIT, which leads to the vendor `SideJITServerConfigView` | `AppManagementView.swift:925` |
| Offload App | `Views/Library/AppOffloadView.swift:3` |
| Install with Another Account / Review Installation | `Views/Library/OtherTeamInstallationView.swift:4, 57` |
| Updates list (up to 7 state sections) | `Views/Library/GitHubUpdatesView.swift:35` |
| App update status | `GitHubUpdatesView.swift:180` |
| Update detail / review ("App Update") | `Views/Library/GitHubUpdateDetailView.swift` *(partial)* |
| GitHub Updates source settings, Versions, Version Details | `Views/Library/GitHubUpdateSettingsView.swift:4, 316, 368` |
| GitHub repository import, token picker | `GitHubRepositoryImportView.swift`, `GitHubTokenPickerView.swift` *(not read)* |
| LiveContainer guest detail | `Views/LiveContainer/LiveContainerViews.swift:305` |
| LiveContainer import / handoff | `Views/LiveContainer/LiveContainerImportView.swift` *(partial)* |

### Accounts tab

| Screen | File |
| --- | --- |
| Accounts list | `Views/Accounts/AccountsView.swift:4` |
| Sign-in sheet | `Views/Accounts/AppleIDSignInSheet.swift` |
| Apple ID detail | `AccountsView.swift:168` |
| App IDs, Profiles and Certificates lists | `AccountsView.swift:330, 356, 387` *(partial)* |

### Settings tab

| Screen | File | Rows |
| --- | --- | --- |
| Settings root | `Views/Settings/SettingsView.swift:4` | 9 |
| App Refresh, Daily Refresh Guide, Cellular Shortcuts | `SideStoreSettingsPages.swift:6, 89, 113` | 9–12 / 7 / 3 |
| Install & Signing | `SideStoreSettingsPages.swift:136` | 7 |
| Local Connection, Help, Connection Method | `LocalConnectionSettingsView.swift:3, 124, 172` | 10–13 / ~11 / 2 |
| Permissions | `SettingsView.swift:51` | 3–5 |
| LiveContainer connections | `LiveContainerViews.swift:160` | up to 6 buttons per connection |
| Health Check (vendor `HealthCheckView`) | `Vendor/SideStore/.../HealthCheckView.swift` | — |
| Advanced | `SettingsView.swift:91` | 8 |
| Connection & Pairing ("Pairing & Ports") | `SideStoreSettingsPages.swift:176` | 11–13 |
| Anisette, plus vendor `AnisetteServersView` | `SideStoreSettingsPages.swift:345` | 9–10 |
| Storage, Folder detail, Cached Files, Review IPA Copies sheet | `SideStoreSettingsPages.swift:480, 691`, `StorageFilesView.swift` | — |
| Skipped Updates, GitHub Tokens / Token editor, Default token, GitHub Update Logs, Diagnostics | `Settings/*` *(partial)* | — |

### Shared components

- `SideKickLibraryAppRow`: 52 pt icon with a 12 radius.
- `ImportedIPARow`.
- `fullWidthListSeparators`.
- `LiveContainerGuestIcon`.
- `GitHubUpdateAppIcon`: 44 pt with a 10 radius.
- `GitHubUpdateDownloadControls`.
- `UnsavedSettingsGuard`.
- `SideKickTheme`: 14 lines, blue and violet, no asset catalogue colour.

---

## 2. Audit findings

Severity levels:

- **P1:** breaks comprehension or a core task.
- **P2:** significant friction or inconsistency.
- **P3:** polish.

### 2.1 Cross-cutting design-system problems

| # | Sev | Finding | Evidence |
| --- | --- | --- | --- |
| X1 | P1 | **No design system.** The theme is one blue constant. There's no AccentColor asset, so tint only comes from `.tint(.sideKickAccent)` on a SwiftUI `@main` that the code itself calls dormant. The real UIKit host may fall back to system blue, which matches the screenshots. | `SideKickTheme.swift`, `SideKickApp.swift:5-22`, all screenshots |
| X2 | P2 | **Six button treatments for primary actions:** `.borderedProminent` capsule (Refresh, Try Again, JIT); `.bordered` capsule (Open, Close); `.plain` (Update, Send to LiveContainer); plain list rows (Install, Download IPA); prominent non-capsule (install confirm); toolbar text (Done). | AppManagementView 142-189, 358-433, 645-683, 1107; S11, S17–S18 |
| X3 | P2 | **Hard-coded semantic colours.** `.red` ×6, `.orange` ×10+, `.green` ×5, `.blue.gradient` ×1. Errors are red on some screens and secondary grey on others. | Sub-audit lists |
| X4 | P2 | **Icon geometry differs:** 76/17, 52/12 and 44/10 pt. None use the continuous app-icon ratio (~22.37%). Fallback icons use different gradients. | AppManagementView:66, SideKickLibraryAppRow, GitHubUpdatesView:256 |
| X5 | P2 | **Titles duplicated.** The detail header repeats the inline nav title. The status screen shows the large title *and* the nav title (S6–S9: "Re-sign Status" twice). | S6–S9, S17 |
| X6 | P2 | **Terminology drift:** "Apple ID" vs "Apple Account"; "Pairing & Ports" vs "Connection & Pairing"; "GitHub Update Source" vs "GitHub Updates" vs "Versions & GitHub Source" vs "Update Source & Installed Version"; "SideStore" brand leaks. | Settings sub-audit |
| X7 | P2 | **Over-explaining footers.** Most sections carry 2–5 sentences of caveats, some longer, e.g. Storage (~80 words), GitHub source (S16), LiveContainer connection, Actions token (S10). The explanation competes with the controls. | S1, S10, S11, S16 |
| X8 | P2 | **Legacy tab API.** `.tabItem`/`.tag` instead of `Tab {}`. There's no `.tabBarMinimizeBehavior`, and no bottom accessory for long-running operations. | ContentView:17 |
| X9 | P3 | Every screen re-implements `.alert(isPresented: Binding(get: msg != nil…))`. Success notices reuse error alerts ("IPA imported", Storage clean report). | HomeView:398, Storage:686 |
| X10 | P2 | **Destructive actions without confirmation:** Remove Imported IPA (detail and context menu), Remove GitHub Update Settings. Removing a queued IPA does confirm, so behaviour is inconsistent. | AppManagementView:294, HomeView:249, GitHubUpdateSettingsView:127 |

### 2.2 My Apps (S3–S4)

| # | Sev | Finding |
| --- | --- | --- |
| H1 | P2 | The **Updates** row is a full card even when it says "Apps Are Up to Date". That's the most prominent element on the screen and it carries no actionable information. |
| H2 | P2 | **Refresh All** is a small header text link, while expiry is the app's core job. No screen answers "how long until something expires?" at a glance. |
| H3 | P2 | Every installed row reads "Signing in 7 days". Repeated identical metadata is noise. The useful signal is the exception (≤2 days, expired, failed). |
| H4 | P3 | Context menu "More Options" duplicates the row tap. Context-menu refresh runs silently, while detail refresh opens the console. |
| H5 | P3 | Four sections can appear (Installed, Inactive, LiveContainer, Ready to Install), each with its own row grammar. |
| H6 | P3 | The empty state only offers Files, while the toolbar also offers URL. |

### 2.3 App detail (S17–S18, S12, S2)

| # | Sev | Finding |
| --- | --- | --- |
| D1 | **P1** | **Primary action hierarchy is inverted.** "Open" sits alone in a section titled "Open" in a dimmed bordered capsule. "Refresh" is a bright prominent capsule in a section titled "Refresh". Two full-width capsules in separate cards, both with redundant headers. |
| D2 | **P1** | **"App Settings" is a junk drawer.** It holds GitHub Update Source, Share IPA, Re-sign, Offload / Restore and Enable JIT. These are actions, not settings. Re-sign uses the same icon as Refresh. "Share IPA" can dead-end with an error. |
| D3 | P2 | **"Options" appears twice with different meanings:** refresh-account picker vs update-team picker. Re-sign, Refresh Options and Choose Account are three copies of one account picker. |
| D4 | P2 | Offload/Restore has **three entry points**: Restore or Recover row, Offloaded section, App Settings row. |
| D5 | P2 | The update result lives in GitHub status pages. "Review Update" is a plain row buried mid-card (S12, circled in your capture), and the detail screen itself never says "Update available". |
| D6 | P3 | Details shows Bundle ID, team and signing account to everyone. These are useful but advanced. |
| D7 | P3 | JIT has its own inline progress and error pattern instead of the shared status screen. The `#available(iOS 17)` branch is dead code on an iOS 18 target. |

### 2.4 Operation status (S5–S9): the weakest screen

| # | Sev | Finding |
| --- | --- | --- |
| O1 | **P1** | **The failure message appears three times:** summary ("couldn't re-sign"), grey footnote label, and red log line. The actual cause is rendered *quieter* (secondary footnote) than the generic summary. |
| O2 | **P1** | **Raw `IXErrorDomain`/`NSUnderlyingError` dumps dominate the screen** (S6–S8). There's no human translation, no "what to do", and no copy or share action for support. |
| O3 | P2 | The log is mostly "pipeline progress · N%" every 5%, which duplicates the progress bar. Open by default for Offload and closed for others. |
| O4 | P2 | `VStack` with no `ScrollView`, so long errors and an expanded log can overflow on small phones and at large Dynamic Type. |
| O5 | P2 | **Try Again**, **Reconnect** and **Close** are three stacked capsules with no hierarchy. "Close" is a tiny tinted pill (S5–S9). Reconnect is offered by keyword-matching the error string. |
| O6 | P2 | While running, the nav bar is hidden and there's no escape or reassurance. During the S5 capture the iOS Low Battery banner overlapped the title. The screen also gives no "keep SideKick open / VPN connected" guidance. |
| O7 | P3 | The bar is a thin linear `ProgressView`. Stages exist (certificate, permissions, signing, installing) but aren't shown. A Blank-Street-style **stage tracker** fits this screen naturally. |

### 2.5 Updates (S2, S10–S12, S16)

| # | Sev | Finding |
| --- | --- | --- |
| U1 | P2 | Up to **seven state sections** in the Updates list. Users care about *Available* and *Needs attention*. Everything else is "Up to date". |
| U2 | **P1** | **App Update review (S10–S11):** <ul><li>The header reads "0.8.0 (140) → Build 137 (unknown build) / Build 137". That's contradictory, it repeats itself, and it shows a downgrade arrow.</li><li>The token footer floats at the top.</li><li>"Download IPA" and "Skip This Build" sit in a card titled "Download", and "Already Installed This Build" in another titled "Update Options".</li><li>An "Available Builds" list sits between the summary and the action.</li><li>There are five sections before the decision.</li></ul> |
| U3 | **P1** | **GitHub Updates source settings (S16):** <ul><li>An ~80-word footer.</li><li>Four version buttons with mixed casing: "Load Build History", "Reload versions", "I Don't Know the Installed Build", "Load older versions".</li><li>Save and destructive Remove sit side by side as plain rows, and Remove has no confirmation.</li><li>It's a form-like screen with an explicit Save plus an unsaved-changes guard, when most fields could validate and save inline.</li></ul> |
| U4 | P2 | "Mark installed" exists in three places with three labels: "Already Installed This Build", "I Installed This Build", "This Version Is Already Installed". |
| U5 | P3 | There's both a toolbar refresh and pull-to-refresh, plus "Check Again" on the status page. |

### 2.6 Accounts (S1, S15)

| # | Sev | Finding |
| --- | --- | --- |
| A1 | P2 | The list row is bare text with no avatar or status. Account health (session valid, certificate count, App ID capacity) is only visible one level down. |
| A2 | P2 | Apple ID detail shows "App IDs available 6 of 10" as plain text. It's the most decision-relevant number in the app and could be a capacity gauge. |
| A3 | P3 | The developer-records footer ("profiles and certificates don't prove…") is engineering caveat copy. |
| A4 | P3 | The sign-in sheet uses the medium detent, so the keyboard can cover the fields. Sign-in only starts after the sheet dismisses, so errors appear on a different screen. |
| A5 | P3 | An empty "Sign In Again" section renders when it isn't needed. |

### 2.7 Settings (S13–S14)

| # | Sev | Finding |
| --- | --- | --- |
| S1 | P2 | **Local Connection is reachable three ways:** root, Advanced → Pairing & Ports, and a Help page that loops back to itself. Health Check is reachable twice, and so are the GitHub Update Logs. |
| S2 | P2 | Root groups are by implementation ("Apps", "Integrations", "Tools") rather than by user intent. "Connection" is the thing users actually troubleshoot, yet it's split across Local Connection, Pairing & Ports, Health Check and Anisette. |
| S3 | P2 | **App Refresh** mixes everyday toggles with keep-alive internals (audio/location), Shortcuts honour-system buttons and a "SideStore" footer. The "I've Added the Shortcut" button can't be undone. |
| S4 | P2 | **Connection & Pairing:** a TextField *and* a Stepper for the same port value, plus a red inline error, plus a Save button. That's four controls for one rarely changed number. |
| S5 | P2 | **LiveContainer connections:** six buttons per connection. "Reconnect" and "Replace" do the same thing, and "Add Another Directory" is repeated in every section. |
| S6 | P3 | **Anisette:** the Server URL stays editable while on-device mode is on, saving shows no spinner, and status is a loose footnote section. |
| S7 | P3 | **Storage:** ~80-word footers, the Clean report shown in an error alert, and no Select All in the review sheet. |
| S8 | P3 | The unsaved alert has no Cancel. The custom Back button loses swipe-back. |
| S9 | P3 | Duplicate SF Symbols: `square.stack.3d.up` (Apps tab, LiveContainer, Cellular shortcuts); `list.bullet.clipboard` ×2. |

### 2.8 Onboarding

| # | Sev | Finding |
| --- | --- | --- |
| R1 | P2 | `canContinue` always returns true. The VPN page can show three `.borderedProminent` buttons plus the prominent bottom button, so there's no single primary action. |
| R2 | P3 | Hard-coded green, a 24 pt custom card, and a "STEP n OF 4" caption plus a linear bar. The Plasma reference does this better: a numbered checklist with one Continue button. |

---

## 3. Redesign decisions

### 3.1 Design tokens (new `DesignSystem/`)

- **Brand colour: "SideKick Teal"**, defined as an `AccentColor` asset with light and dark variants so UIKit-hosted views also inherit it:
  - Light `#00857F`: ≈4.6:1 on white, passes AA for text.
  - Dark `#3DD6C6`: ≈10:1 on black.
  - Tinted fill for prominent buttons: the same hue, with white text in light mode and near-black text in dark mode (contrast check required).
  - Retire `sideKickViolet` and the gradient. The app icon keeps its own artwork.
- **Semantic colours** come from one place:
  - `.green`: success, signed.
  - `.orange`: expiring, needs attention.
  - `.red`: failed, destructive.
  - `.secondary`: informational.
  - Always paired with an SF Symbol, never colour alone.
- **Typography:** SF Pro only, through text styles. Large title for tab roots; `.title2.bold` for hero headlines on status screens; `.headline` for row titles; `.subheadline.secondary` for metadata; `.footnote` reserved for genuine footers. No fixed point sizes, so Dynamic Type works throughout.
- **Spacing:** 4-pt scale (4/8/12/16/20/24/32). Inset-grouped list defaults everywhere instead of custom paddings.
- **Icon geometry:** one `AppIconView(size:)` that uses a continuous corner ratio of 0.2237, with sizes 44 (list), 60 (featured) and 88 (hero), and one neutral fallback tile.
- **Shared components** replacing the duplicates:
  - `AppIconView`
  - `StatusBadge`: an icon plus a short label, with semantic tints
  - `PrimaryActionButton`: Liquid Glass prominent on iOS 26, `.borderedProminent` fallback
  - `AccountPicker`: one view replacing the three
  - `StageProgressView`
  - `.errorAlert($message)` and `.notice($message)` modifiers
  - `ConfirmDestructive` helper

### 3.2 Liquid Glass usage (selective)

Liquid Glass goes on these surfaces, with `#available(iOS 26, *)` and iOS 18 fallbacks:

- **System bars** pick up glass automatically when built with Xcode 26. I'll stop overriding backgrounds (remove the explicit `.background(systemGroupedBackground)` on lists) so the native scroll-edge effect works.
- **Tab bar:** migrate to `Tab {}` and add `.tabBarMinimizeBehavior(.onScrollDown)`. Add `.tabViewBottomAccessory` for an in-progress operation, like "Refreshing 2 of 5", which you can tap to open the status screen. That makes long operations ambient instead of modal.
- **Primary actions** use `.buttonStyle(.glassProminent)`; secondary actions use `.glass`. Each screen gets at most one prominent action, and it lives in a bottom safe-area inset on detail and status screens (the Plasma and Onyx pattern).
- **Toolbar** "+" and Refresh controls stay as native toolbar items, which iOS 26 renders as glass.
- **Not used:** glass cards for content, glass list rows, or custom blur. Content stays on standard grouped surfaces.

### 3.3 Information architecture

**Tabs** stay at three: **Apps**, **Accounts**, **Settings**. Updates stays inside Apps, as a filter or section rather than a fourth tab. I considered adding a Search tab and don't recommend one: library sizes are small, so `.searchable` on My Apps is enough once there are more than about 8 apps.

**My Apps:**
- Replace the Updates card with a compact **status header**:
  - Updates available: an accent "*n* updates" row.
  - Otherwise: a calm line such as "All apps signed · next expiry in 6 days".
  - A **Refresh All** glass button in the toolbar, not the section header.
- Rows show metadata only when it matters: an expiry badge when 2 days or fewer remain, update available, refreshing, or failed. Otherwise just name and version.
- Sections: *Installed*, *LiveContainer* and *Ready to Install*. Inactive apps merge into Installed with an "Offloaded" badge.
- Context menu: Open, Refresh, Share IPA, and Remove (with confirmation). Drop "More Options".

**App detail:** redesigned as a hero header plus actions.
1. Hero: 88 pt icon, name, version, and a `StatusBadge` such as "Expires in 7 days" or "Update available · 3.9.1".
2. One **primary** button pair under the hero, App Store style:
   - **Open** (prominent), plus a **Refresh** glass button.
   - When an update is queued or available, **Update** becomes primary.
   - If offloaded, **Restore** is primary.
3. An **Update** row, shown only when relevant, that leads into the review screen.
4. A "More" `Menu` in the toolbar (`ellipsis.circle`) with Re-sign with Another Account…, Offload…, Share IPA, Enable JIT…, Update Source…, and Remove.
5. A **Details** disclosure, collapsed by default, with Signing account, Team, Bundle ID and Expires.
6. The section headers "Open", "Refresh" and "App Settings" are removed.

**Account selection:** one `AccountPicker(purpose:)` sheet shared by refresh, re-sign and install. It shows a single explanatory sentence per purpose, and other-team accounts sit in a separate "Other teams · installs a separate copy" group.

**Operation status:** rebuilt with the Blank Street pattern.
- A hero headline: "Refreshing Spotify", "Spotify is refreshed", or "Couldn't refresh Spotify".
- A **stage tracker** (Preparing → Signing → Installing → Done) instead of a percentage plus a thin bar. The fine-grained percentage stays as an accessibility value.
- On failure:
  - **One** error card: a human summary mapped from known errors, such as App Group missing, IX placeholder or bundle-ID mismatch, and session expired.
  - A "What you can do" line.
  - The raw error behind **Technical Details**, with a **Copy** button.
- The log is hidden behind "Activity" and drops the "progress · N%" lines, logging stage transitions only.
- The bottom bar has one prominent button (Try Again or Done). Secondary actions (Reconnect, Close) are glass or text buttons, and Reconnect is driven by a typed error category rather than string matching.
- The layout is wrapped in a `ScrollView` and respects safe areas.
- While running, the screen shows "Keep SideKick open" guidance. A background-and-accessory path follows later.

**Updates:**
- The list collapses to *Available*, *Needs Attention* and *Up to Date*. Skipped and Waiting fold into Up to Date with a badge.
- **Update review**:
  - A hero with "Installed 0.8.0 (136)" and "Available Build 137", with no contradictory labels.
  - Release title and notes.
  - A single bottom **Update** button.
  - A toolbar menu for Skip, "I've Already Installed This", and Choose Another Build.
  - The token notice appears only when a token is actually missing, as an inline warning.
- **Source settings**:
  - Three short sections: Repository, Build Source, and Installed Build.
  - The version buttons collapse into one "Installed Build" picker row.
  - Remove Source becomes a confirmed destructive action at the bottom.
  - Footers trimmed to one sentence.
- One shared label: **"I've Installed This Build"**.

**Accounts:**
- Rows get an initials avatar, email, team, and a status badge (Signed in / Sign in required).
- Detail opens with a hero (avatar, email, team, account type) and an **App ID capacity gauge** (`Gauge`, 6 of 10).
- Developer records are grouped under "Developer Resources".
- Remove Apple ID stays at the bottom with its confirmation, and its footer shrinks to one line.
- "Apple Account" is used everywhere (Apple's current term).
- The sign-in sheet uses the large detent, focus management and submit-on-return, and shows errors inside the sheet.

**Settings root**, regrouped by intent:
- **Signing:** App Refresh, Install & Signing, Notifications. Permissions folds into Notifications plus Background Refresh status.
- **Connection:** Local Connection, with pairing file, method, verification and Health Check merged into one screen. Pairing ports move to its Advanced disclosure.
- **Integrations:** LiveContainer.
- **Advanced:** Anisette, GitHub Tokens, Skipped Updates, Storage, and Diagnostics (with GitHub logs inside).
- **About:** Version, GitHub, Open-source notices (a real link).

**Settings subpages:**
- **App Refresh:** primary toggles first. "Background keep-alive" goes behind an Advanced disclosure. The Shortcut setup becomes a single "Set Up Daily Refresh" row leading to a step guide with a proper numbered list.
- **Pairing port:** an Automatic/Custom picker. Custom reveals one number field that validates on commit. The Stepper and Save are dropped.
- **LiveContainer connections:**
  - Each connection becomes one row with status and last scan.
  - Its actions (Rescan, Change Folder, Disconnect, Forget) move to swipe actions and a context menu, with the details screen one level down.
  - The toolbar "+" adds a connection.
  - Reconnect and Replace merge into Change Folder.
- **Anisette:** disable the URL field in on-device mode, show progress on save, and report results through `.notice`.
- **Storage:** one-sentence footers, Select All in the review sheet, and the clean result shown as a notice.
- **Unsaved-changes alert:** add Cancel. The guard keeps the system back button and uses `.interactiveDismissDisabled` plus a confirmation on back where possible.

**Onboarding:** a Plasma-style checklist.
- Welcome hero, then one screen listing the three steps as status rows (Apple Account ✓, Pairing File, Local Connection).
- Each row opens its task in a sheet.
- A single bottom **Continue** or **Finish** button; "Set up later" is a text button.
- Removes the multiple prominent buttons and the dead gating code.

### 3.4 Copy rules

- Use one short sentence of footer only when it prevents a mistake. Move caveats to a Help or "Learn more" view.
- Title Case for buttons and navigation titles, sentence case for footers.
- Don't use "SideStore" in UI.
- Use verbs for actions: "Refresh", "Update", "Restore". Use nouns for navigation.

---

## 4. Implementation plan (proposed order)

Each phase builds, runs `graphify update .`, and is reviewed before the next starts.

1. **Foundation:**
   - AccentColor asset (teal, light/dark) and confirmation that the UIKit host applies it (patch/integration check).
   - `DesignSystem/` tokens and shared components (§3.1).
   - Alert and notice modifiers.
2. **Shell:** `Tab {}` migration, minimize behaviour, an operation bottom accessory, and removing background overrides that defeat glass.
3. **Operation status** (highest user pain): new `OperationStatusView`, error mapping table, stage tracker, and copy-to-clipboard technical details.
4. **App detail and the account picker:** hero, primary actions, toolbar More menu, Details disclosure, and consolidating the three pickers.
5. **My Apps:** status header, conditional row metadata, context menu, and the merged Inactive section.
6. **Updates:** list collapse, review screen, source settings simplification, and unified "I've Installed This Build".
7. **Accounts:** rows, detail hero with capacity gauge, and sign-in sheet.
8. **Settings:** regroup the root, merge Connection, and simplify the App Refresh, Pairing, LiveContainer, Anisette and Storage subpages.
9. **Onboarding:** checklist redesign.
10. **Sweep:**
    - Remove hard-coded colours, dead code (`#available(iOS 17)`, `canContinue`) and duplicate entry points.
    - Make terminology consistent.
    - Leave vendor views (HealthCheck, AnisetteServers, SideJIT) unstyled internally, but give them consistent titles and entry points. Vendor code changes follow `Vendor/SideStore/AGENTS.md`.

Business logic, persistence keys (`@AppStorage` names), services and signing flows are not changed. Every phase is UI-only unless noted.

## 5. Verification plan

- **CI:** `.github/workflows/ios-build.yml`, which uses Xcode 26, must stay green. Release-manifest Python tests must still pass. Builds can't run on this Windows machine.
- **On device or Simulator, per screen:**
  - light and dark mode
  - AX5 Dynamic Type
  - VoiceOver order
  - Reduce Transparency and Increase Contrast (glass fallbacks)
  - Reduce Motion
  - iPhone SE and Pro Max sizes
  - final row clearance under the floating tab bar
  - keyboard on the sign-in and source settings screens
- **State checks:** loading, empty and error for My Apps, Accounts, Updates, LiveContainer and Storage. Failure screens should be exercised with the three real errors from S5–S9.
- **Honest reporting:** screens checked only in source will be labelled as such. Screenshots will be requested for anything I can't render.

## 6. Open questions for you

1. Is the teal OK as a **replacement** for the blue, including the tab-bar selection? The app icon stays as is.
2. Should Refresh All live in the toolbar, as proposed, or stay a visible button on the list?
3. Are you happy for Re-sign, Offload, JIT and Share to move into a "More" menu on app detail? It removes five rows but adds one tap for those actions.
4. Should I merge Local Connection, Pairing and Health Check into one **Connection** screen?

---

## 7. Decisions after review (17 October 2026)

### 7.1 Answers

| Question | Decision | Reasoning |
| --- | --- | --- |
| Teal replaces blue | **Yes, everywhere**, including the tab bar selection, toolbar items, links and prominent buttons. It ships as an `AccentColor` asset so the UIKit host inherits it too. | Your decision. |
| Refresh All placement | **Neither the toolbar nor the section header.** It becomes the action on a new **signing status row** at the top of My Apps: "All apps signed · next expiry in 6 days", with a teal **Refresh All** glass button. | Refreshing is the app's core job, so it deserves the primary spot. In the toolbar it would sit next to "+" with no context. Pairing it with the expiry fact explains *why* you'd tap it, and the row replaces the low-value "Apps Are Up to Date" Updates card. |
| "More" menu on app detail | **Yes, with refinements:** <ul><li>The toolbar `ellipsis.circle` menu holds **Sign with Another Account…** (renamed from Re-sign, which looked like Refresh), **Offload…**, **Enable JIT…** and **Remove…**, with the destructive item last behind a divider.</li><li>**Share IPA** gets its own toolbar share button, shown only when an IPA exists. That removes the dead-end.</li><li>**Update Source** stays a visible row in an **Updates** section, because it shows status ("Up to date · Build 137"), not just an action.</li></ul> | This is the Refactoring UI action hierarchy: Open and Refresh are primary/secondary, rare actions are tertiary, and destructive actions get tertiary treatment until their confirmation dialog. |
| Merge Connection | **Yes.** One **Connection** screen: <ul><li>A status hero: "Ready to install" in green with a checkmark, or "Needs setup" in orange.</li><li>A three-row checklist with live status: Pairing File, Local VPN (method + connect), Device Verified. Each row's trailing button is the next action.</li><li>**Run Health Check** as the only prominent button.</li><li>An **Advanced** disclosure holding Connection Method details, Pairing Port and Help.</li><li>Anisette stays in Settings → Advanced.</li></ul> | It removes three duplicate entry points and the Help → Local Connection loop. Onboarding can reuse the same checklist, so it shares one component. |

### 7.2 Refactoring UI, translated to native iOS

The skill is written for the web (px, CSS shadows). These are the rules adopted here, with any deviation made explicit.

**Spacing scale (pt):** `4 8 12 16 24 32 48 64`. Adjacent steps are ≥25% apart from 12 upward. I'll define these as `Spacing.xs…xxxl` and won't allow any other literal paddings in SideKick views. Lists keep the system insets; the scale governs custom layouts such as the hero, status and onboarding screens.

**Type:** the skill's 12–72 px scale is replaced by **iOS text styles**:

| Text style | Size (pt) |
| --- | --- |
| caption | 12 |
| footnote | 13 |
| subheadline | 15 |
| body | 17 |
| title3 | 20 |
| title2 | 22 |
| title | 28 |
| largeTitle | 34 |

This is a deliberate deviation. The text styles are Apple's hand-picked scale, they're the only way to honour Dynamic Type, and they keep the spirit of "never invent a size". There will be no `.font(.system(size:))` except for SF Symbol hero glyphs, and those use `.imageScale` or `@ScaledMetric`.

**Weights:** two. Regular for text, semibold for emphasis. Bold only for `largeTitle`/`title` headlines. Nothing lighter than regular; to de-emphasise, use colour.

**Text colours, three at most:** `.primary`, `.secondary`, and `.tertiary`. `.tertiary` (tertiaryLabel) does **not** reach 4.5:1, so it's restricted to non-essential decoration such as timestamps, and only where the same information exists elsewhere. Everything a user must read is primary or secondary.

**Labels are a last resort.** This drives many concrete changes:
- "Version 3.9.0" becomes "3.9.0" under the app name, since the format already identifies it.
- "Signing in 7 days" becomes an "Expires in 7 days" badge, shown only when ≤2 days remain or the app has failed.
- "App IDs available: 6 of 10" becomes a gauge reading "6 of 10 App IDs left".
- The Apple ID card drops its "Apple ID / Team / Account type" label column. It becomes a hero: the email as the headline, then "Huzaifah Nandhla · Free account".
- `LabeledContent` stays only on spec-sheet screens: Details, Build Details and Storage.

**Emphasise by de-emphasising:**
- Status screen log text goes secondary and smaller.
- Section headers that just name the only control are dropped ("Open", "Refresh", "Download", "Update Options").
- The error card is the only coloured surface on a failure screen.

**Actions:** one primary per screen, which is solid teal: `.glassProminent` on iOS 26 or `.borderedProminent` on iOS 18. Secondary uses `.glass` or `.bordered`. Tertiary is plain teal text. Destructive actions are tertiary red text, *except* inside their confirmation dialog, where they become the primary.

**Never grey on colour.** On a teal button, text is white in light mode. In dark mode it's the dark teal 900, not white, because white on `#3DD6C6` fails contrast. Status-tinted backgrounds, such as the error card, use a 100-shade tint with 800/900 text in the same hue, never `.secondary`.

**Colour is never the only signal.** Every semantic colour comes with an SF Symbol and words.

**Icons:** never upscale a small glyph. Status glyphs at hero size sit inside a tinted circle, for example a 64 pt circle in red 100 holding a 28 pt `xmark` in red 700. App icons use one `AppIconView` with a continuous corner ratio of 0.2237, at 44, 60 and 88 pt.

**Radius:** one family. System continuous corners for app icons. Inset-grouped lists and Liquid Glass capsules for controls. Custom cards (the error card and onboarding checklist) match the list section radius. The ad-hoc 14 and 24 pt rectangles go.

**Shadows:** none in custom code. Depth comes from native materials and Liquid Glass, which the skill's z-axis principle maps onto directly: content sits on grouped surfaces, and controls float on glass.

**Spacing between groups is greater than spacing within them.** The hero gets 24–32 pt to the actions and 8 pt inside itself. The stage tracker's labels sit 4 pt from their segments and 24 pt from the error card.

**Line length:** error, explanatory and onboarding text get `maxWidth ≈ 34em`-equivalent, about 560 pt, for iPad and landscape.

**Opacity scale:** `.05 .1 .2 .4 .6 .8`, used only for tints and disabled states.

### 7.3 Teal ramp (HSL, hue ≈ 176)

Contrast values are calculated estimates. I'll recheck them with a contrast tool before shipping.

| Step | HSL | Use |
| --- | --- | --- |
| 100 | hsl(172, 60%, 94%) | light tint backgrounds |
| 200 | hsl(173, 58%, 84%) | selected row tint (light) |
| 300 | hsl(174, 62%, 66%) | dark-mode text on dark surfaces |
| 400 | hsl(174, 65%, 54%) `#3DD6C6` | **dark-mode accent** (≈10:1 on black) |
| 500 | hsl(176, 90%, 34%) | badges, icons |
| 600 | hsl(177, 100%, 26%) `#00857F` | **light-mode accent** (≈4.6:1 on white) |
| 700 | hsl(178, 100%, 21%) | pressed state (light) |
| 800 | hsl(180, 95%, 16%) | text on 100 tint |
| 900 | hsl(182, 90%, 11%) | text on dark-mode teal buttons |

The hue rotates slightly toward blue as it darkens, which keeps the dark shades from turning muddy (systems.md technique). Greys stay iOS system greys (`systemGray`–`systemGray6` and the label colours) rather than a custom ramp. They already give 8+ adaptive shades, and they're what a native app should use. Success, warning and error use system green, orange and red, plus 100/800 tints defined once in the asset catalogue. No runtime `opacity()` derivations are used for shades.

### 7.4 Signature screens, decided

**My Apps:**
- Large title.
- The signing status row (§7.1).
- An "*n* updates available" row in teal, shown only when there are updates.
- An Installed section whose rows show icon, name, and version in secondary text. A trailing badge appears only for exceptions (expiring, update, offloaded, failed).
- LiveContainer section.
- Ready to Install section.

**App detail:**
- An 88 pt hero.
- An **Open** (primary) and **Refresh** (secondary glass) pair side by side, App Store style. When an update is waiting, **Update** takes the primary slot and Open becomes secondary.
- An Updates section with one row.
- A collapsed Details section.
- Toolbar: share and the More menu.

**Operation status:**
- A hero glyph in a tinted circle, plus a title2 headline ("Refreshing Spotify" / "Spotify refreshed" / "Couldn't refresh Spotify").
- A four-segment stage tracker (Blank Street pattern).
- On failure, one red-100 error card with a human summary and a "What you can do" line. Under it, **Technical Details** (raw error plus a Copy button) and **Activity**, both collapsed.
- A bottom safe-area bar with one primary button (**Try Again** or **Done**) and a tertiary **Close** or **Reconnect Account**.

**Onboarding:** a welcome hero, then one checklist screen shared with the Connection screen, with a single bottom button.

The implementation order is unchanged from §4. Phase 1 is the foundation: the AccentColor asset, `DesignSystem/` tokens, `AppIconView`, `StatusBadge`, action button styles, alert and notice modifiers.

### 7.5 Release version

During implementation, bump the marketing version from `0.8.0` to **`0.9.0`**:

- `scripts/embed-local-vpn.py:132` stamps `MARKETING_VERSION` into the build. This is the actual source of the shipped version.
- `project.yml:6` has a comment that mentions the version.

Also check the release-manifest fixtures (`Tests/ReleaseManifest`) and the update-channel version comparison. CI keeps setting `CURRENT_PROJECT_VERSION` from the run number.

---

## 8. Implementation status (17 October 2026)

All of this has been checked against the source only. Nothing has been compiled or rendered yet: this Windows machine has no Xcode. CI builds on the `xcode-27` runner, with an iOS 18 deployment target. Release-manifest tests pass (15 passed, 1 skipped on macOS only).

| Area | Done |
| --- | --- |
| Foundation | <ul><li>Colour assets: `SideKickAccent` (`#007A74` / `#3DD6C6`), `SideKickOnAccent` and `SideKickAccentTint`.</li><li>Window tint applied so UIKit sheets and alerts also use the accent.</li><li>`DesignSystem/SideKickComponents.swift`: app icon, status badge, status symbol, avatar, primary/secondary glass button styles, bottom action bar, message alert, detail header.</li><li>New app icon.</li><li>Version 0.9.0.</li></ul> |
| Shell | <ul><li>Tabs use the `Tab {}` API.</li><li>Tab bar minimises on scroll (iOS 26 and later).</li><li>The unsaved-changes alert now has Keep Editing.</li><li>New database error state.</li></ul> |
| Operation status | <ul><li>Hero header and four-stage tracker.</li><li>Errors mapped to plain-language explanations.</li><li>Copyable Technical Details and Activity log.</li><li>One primary bottom action.</li><li>Percent lines removed from the log.</li></ul> |
| App detail | <ul><li>Hero header with status badge.</li><li>Open and Refresh side by side.</li><li>Toolbar Share button and More menu.</li><li>Details collapsed.</li><li>One shared account-picker row.</li><li>JIT steps screen.</li></ul> |
| My Apps | <ul><li>Signing status row with Refresh All.</li><li>Badges only for exceptions.</li><li>Offloaded section.</li><li>Long-press menus on every row type.</li><li>Swipe to refresh or remove.</li></ul> |
| Updates | <ul><li>Three sections.</li><li>Status page with header and badge.</li><li>Review screen with hero and toolbar menu.</li><li>Update Source form saves from the toolbar and asks before Stop Tracking.</li><li>One label everywhere: "I’ve Installed This Build".</li></ul> |
| Accounts | <ul><li>Avatar rows.</li><li>Detail header plus App ID capacity gauge.</li><li>Sign-in sheet at large detent, with focus handling and submit on return.</li></ul> |
| Settings | <ul><li>Root regrouped.</li><li>Merged Connection checklist screen.</li><li>Pairing uses an Automatic/Custom port picker.</li><li>LiveContainer folders as rows with menus and swipe actions.</li><li>Anisette and Storage trimmed.</li><li>Storage review sheet has Select All.</li></ul> |
| Onboarding | <ul><li>A single primary action per page.</li><li>Removed the `canContinue` code that never blocked anything.</li></ul> |

**Not done:**
- A `tabViewBottomAccessory` showing live refresh progress. This needs shared operation state that doesn't exist yet.
- Restyling vendor screens (Health Check, Anisette servers, SideJIT).
- Device checks in light mode, at large Dynamic Type sizes and with VoiceOver.
