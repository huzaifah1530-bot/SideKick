# SideKick frontend visual and usability audit — 17 October 2026

## Overall assessment

The app has a sound native foundation: system tab navigation, grouped lists, clear app icons, and mostly restrained use of the existing blue accent. The main friction is uneven information density. Installed apps, LiveContainer guests, update status, and settings use similar surfaces but apply different rules for what belongs in the first view. The attached screenshots show the app in dark mode; findings about other appearances or the latest branch UI need device verification.

**Evidence:** Screenshot references below use the order of the ten attachments in this request: S1 Apple ID; S2 Apollo update status; S3–S4 My Apps; S5/S8 Settings; S6–S7/S10 SideKick update flow; S9 Accounts. Source references are from the current `codex/ios-ui-redesign` checkout. S6–S7/S10 show an update flow that differs from the current branch's direct compact review route, so they are historical visual evidence, not proof of the current candidate screen.

## Findings, in priority order

1. **P2 · LiveContainer update confirmation · confirmed in source; current screen not pictured.** The guest detail offers **Already Installed This Build** for every available candidate, including a known newer build, while the regular app review shows it only when the installed build is unconfirmed. The guest screen explains that confirmation should follow installation and shows a confirmation alert, but the action remains available beforehand. This makes the same update decision behave differently across an integration and regular apps, and can let a user record an uninstalled build as installed. Apply the same eligibility rule and confirmation language to both paths; retain the LiveContainer handoff action where needed. Sources: `SideKick/Views/LiveContainer/LiveContainerViews.swift:389-415,461-463`, `SideKick/Views/Library/GitHubUpdateDetailView.swift:51-57,299-325`.

2. **P2 · Accounts failure state · confirmed in source; not pictured.** When loading accounts fails and the list is empty, the screen presents both the error with **Try Again** and **No Apple Accounts** with **Add Apple Account**. Those are different states and give conflicting guidance about whether accounts exist. Make the error and true empty state mutually exclusive, as the My Apps screen already does. Source: `SideKick/Views/Accounts/AccountsView.swift:43-71`.

3. **P2 · LiveContainer guest rows on My Apps · confirmed in screenshots and source.** Guest icons, corner radii, horizontal spacing, and row padding use the same shared component as installed apps; their shapes are not independently sized. Guests appear taller because they add separate **Build** and folder-name lines below **Version**, where installed apps use one signing line. The build and folder can matter, especially with multiple folders or snapshots, but S4 repeats **LiveContainer** on every guest directly beneath a **LiveContainer** section heading. Keep the distinctive details when they disambiguate guests or signal an unavailable/reconnect state; otherwise condense the build/folder metadata or move the exact build to details. Preserve the shared icon and padding rules. Sources: `SideKick/Views/Components/SideKickLibraryAppRow.swift:25-53`, `SideKick/Views/Home/HomeView.swift:157-165,437-449`, `SideKick/Views/LiveContainer/LiveContainerViews.swift:15-35`. Evidence: S3–S4.

4. **P2 · Update status hierarchy · confirmed in S2 and source.** The **Up to Date** result is visually outweighed by a long release title, filename, publish time, and checked time. A user checking whether action is needed must scan a large technical card to reach **Check Again**. Lead with the result and current/latest build relationship; disclose release notes, asset name, and timestamps as supporting details. This recommendation applies to the status screen, not the current compact candidate review. Source: `SideKick/Views/Library/GitHubUpdatesView.swift:197-230`. Evidence: S2. S6's buried **Review Update** belongs to an older captured flow; the current route is `GitHubUpdatesView.swift:125-132`.

5. **P2 · Settings grouping · confirmed in S5/S8 and source.** **Health Check** and **Advanced** sit in an unlabeled group between named **Integrations** and **About** groups. The blank heading leaves two unrelated destinations looking like a leftover section. Give the group a meaningful heading or place each item with its closest task context. Source: `SideKick/Views/Settings/SettingsView.swift:23-43`. Evidence: S5/S8.

6. **P2 · App ID capacity placement · confirmed in S3/S4 and source; design recommendation.** **6 App IDs available** appears as the footer of **Installed**, just above LiveContainer guests. It describes signing/account capacity rather than the installed app list and can be mistaken for a count tied to that section. Place it near account or installation capacity information, or surface it when the limit affects an install. Source: `SideKick/Views/Home/HomeView.swift:187-209`. Evidence: S3–S4.

7. **P3 · Update action consistency across app types · source-based design recommendation.** The regular app candidate now has a compact review with the build comparison and primary actions before **Details**. LiveContainer candidates are handled inside the longer guest detail among opening, source settings, token guidance, and handoff controls. The handoff is genuinely different, but the decision to download, skip, or confirm a build should use a similarly clear first step. Keep the specialized send-to-LiveContainer process in the next step or details. Sources: `SideKick/Views/Library/GitHubUpdateDetailView.swift:250-333`, `SideKick/Views/LiveContainer/LiveContainerViews.swift:350-419`. No current guest-update screenshot was supplied.

8. **P3 · List divider alignment · confirmed in source; visual preference to verify.** App rows explicitly extend separators across the icon column, while Settings uses the default inset separator aligned with text. Both are grouped-list surfaces, so the difference weakens component consistency. Choose one native separator rule for comparable rows after checking it on device; the longer guest rows may still benefit from a stronger boundary. Sources: `SideKick/Views/Home/HomeView.swift:157-165`, `SideKick/Views/LiveContainer/LiveContainerViews.swift:15-58`, `SideKick/Views/Settings/SettingsView.swift:8-43`. Evidence: S3–S5/S8.

## Meaningful colour use

The existing blue already identifies selected navigation and ordinary actions; orange labels warn about guest availability, and the compact review uses green for **Already Installed This Build** and a destructive role for skipping. Keep these meanings paired with text and icons. **Suggestion:** use the existing `Color.sideKickAccent` consistently for primary download/selection affordances instead of mixing the token with hard-coded `.blue`; avoid colouring entire app cards. The current token and action styles are in `SideKick/DesignSystem/SideKickTheme.swift:4-13` and `SideKick/Views/Library/GitHubUpdateDetailView.swift:310-319,352,626`.

## Branding opportunities

**Suggestion:** on My Apps, reserve the SideKick blue for the Updates affordance and a genuinely actionable state such as an available update or Refresh All. S3 shows an appropriately calm neutral homepage already; a larger branded banner or new palette would add noise. Use the existing brand token and retain text/status cues, including when colour is unavailable. Sources: `SideKick/DesignSystem/SideKickTheme.swift:4-13`, `SideKick/Views/Library/GitHubUpdatesView.swift:9-23`, `SideKick/Views/Home/HomeView.swift:187-209`.

## Requires visual verification

- Render the **current branch's** compact app update review and LiveContainer guest update state. S6–S7/S10 appear to predate the direct candidate route and cannot verify the present action hierarchy.
- Check the last row at the end of My Apps, Settings, and update lists with the floating tab bar. S3–S5/S7/S10 show content behind the native bar during scrolling; these captures do not establish whether the final row remains readable and tappable at scroll end.
- Check light mode, larger Dynamic Type, long app/folder names, VoiceOver order, loading/error states, and multiple LiveContainer connections on an iOS device or Simulator. Only dark-mode screenshots of the listed states were supplied; no simulator render of this checkout was available for this audit.

The single-account whitespace in S9 and different icon sizes in app rows versus detail headers appear appropriate to their contexts and are not findings.

## Implementation status — 17 October 2026

| Finding | Status | Outcome |
| --- | --- | --- |
| 1. LiveContainer build confirmation | **Partially fixed** | Confirmation is now offered only when the installed build is unknown or the candidate IPA is queued. It says **I Installed This Build** and retains the explicit post-installation alert. A queued IPA does not prove installation, so the user must still attest after LiveContainer finishes. |
| 2. Accounts failure/empty conflict | **Fixed; awaiting device verification** | Error, initial loading, and true empty states no longer appear together. |
| 3. Tall LiveContainer rows | **Fixed; awaiting device verification** | Version and distinct build share one line; the folder label appears only with multiple connections or a snapshot. Warning/reconnect lines remain visible. Icons and row padding remain shared. |
| 4. Update status hierarchy | **Fixed; awaiting device verification** | Status, installed/latest versions, and **Check Again** lead; release title, file, and dates are in **Build Details**. Errors remain visible in the status section. |
| 5. Settings grouping | **Fixed; awaiting device verification** | **Health Check** and **Advanced** now sit under **Tools**. |
| 6. App ID capacity placement | **Fixed; awaiting device verification** | Removed the misleading Installed footer and its background capacity fetch. Capacity remains in Apple Account details. |
| 7. LiveContainer update action hierarchy | **Partially fixed; awaiting device verification** | A candidate now shows installed/available builds and download/handoff/skip before technical settings. The required LiveContainer handoff still uses its guest detail screen. |
| 8. Divider alignment | **Deferred: visual evidence insufficient** | The native list and custom full-width rules remain. Check both styles on the current build at normal and large text sizes before changing all app-row dividers. |

**Colour/branding:** Primary download and install accents and fallback icons now use the existing `sideKickAccent`; semantic green, orange, and destructive labels retain text/icon cues. The homepage already uses brand blue sparingly, so no new surface colour was added.

**Validation:** The Windows workspace has no `swiftc`, Xcode, `xcrun`, or iOS Simulator, so these SwiftUI changes are source and graph verified, not compiled or visually verified on the current build. `graphify update .` completed; its AST pass reported only two pre-existing vendor syntax warnings, not these edited views. Release-manifest Python tests passed (16 run, one macOS-only test skipped), and `git diff --check` passed. The current update screens, Accounts loading/error cases, light mode, Dynamic Type, VoiceOver order, and final-row clearance under the floating tab bar still require an iOS build/device check.
