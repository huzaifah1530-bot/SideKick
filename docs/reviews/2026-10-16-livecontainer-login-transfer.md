> Historical implementation: retired by the simpler SideStore offload flow. Data/credential migration described below is no longer shipped.

# LiveContainer login transfer

The existing native transfer only copied files. A guest asking for sign-in is not evidence of lost Documents/Library data: native credentials can live in Keychain, outside both the sandbox and App Groups. This change adds a credential-copy pass before the user can confirm a complete move.

## Flow

1. Export native files and connect the resulting SideKickData folder as before.
2. In LiveContainer, make that folder the guest's default external container and enable Isolate App Group. Close the guest. Link the actual Applications directory in SideKick.
3. On Step 4, tap Transfer Login. For installations made before this change, update/reinstall LiveContainer through this SideKick version first, preserving its data. The native export's original-app reinstall records the native permissions; a profile-only fast refresh is insufficient to establish new signing evidence.
4. The native helper opens again. Select the same SideKickData folder. Readable passwords/session tokens are copied in memory into the destination's granted Keychain group. The original binary is then reinstalled using the existing backup pipeline.
5. Launch the guest and verify the existing login and app data. If it still requests sign-in, keep the native installation; this is an incomplete migration. Only a completed credential pass plus explicit user verification permits offload.

## Trust and data boundaries

The exported manifest must match the installed native ID/version/build. LCContainerInfo.plist must identify that guest and an isolated supported numeric bucket. The actual connected guest's LCAppInfo.plist must set LCDataUUID to that external folder, with a bookmark resolving to the same path. An installed LiveContainer record on the same team must advertise the connection's URL scheme and the exact destination Keychain group in its captured signed permissions. Ambiguous matches stop.

The install pipeline deletes Refreshed.ipa, and the original retained app can still carry its publisher's entitlements. Therefore the post-install metadata cache records only the actual signed application identifier, Keychain groups and URL schemes in CredentialTransferSigning.plist. Temporary SideBackup installs cannot overwrite that evidence. Profile-only refreshes do not create it. No credential bytes are in this file.

Only an explicit login-transfer helper invocation receives the exact source and destination Keychain groups. The signer requires the current team's prefix, a supported LiveContainer destination, and profile permission for every requested group (exact grants or a terminal namespace wildcard). Existing imported-app signing follows its usual path. The packaging helper's placeholder App Group entitlement is unchanged.

The Keychain adapter queries only explicit source groups. It rejects keys, identities, certificates, unreadable/protected items, and bounded-size overflows before writes. Password attributes use an allowlist; destination access-group and LiveContainer's `alis` container ownership marker are supplied explicitly. Source credentials are never changed or deleted. Pre-existing records must have the same owner marker, attributes and bytes. Different data stops rather than overwriting. New records are read back; a normal failure rolls back only exact persistent references inserted by that attempt. A killed process can leave a verified subset in the destination; retry reuses identical owned items. There is no cross-process Keychain transaction, no group-wide deletion and no automatic success after a kill.

LiveContainer 3.8.0 allocates bucket numbers among an app's containers, not globally among all guests; its credential queries do not filter the ownership alias. This change follows that existing routing and rejects colliding identities. It does not claim to provide additional isolation between LiveContainer guests.

The helper also rechecks the selected folder's manifest and container metadata. The normal process guard and storage/VPN lease apply. Offload rechecks destination configuration and requires it to match the completed login destination. Restart clears transient transfer requests. Recovery can reinstall the original binary without copying guest credentials back.

## Limits and verification

Readable generic and internet password items are supported. Secure Enclave keys, protected credentials, certificate/key migration, reverse guest-to-native credential synchronization, different signing teams, custom LiveContainer routing/forks, and guaranteed server acceptance of a copied session are not implemented. No universal promise of preserved login is made. User confirmation is a functional check; a successful byte comparison is not proof Spotify accepts the session.

Swift core tests cover copy/readback, idempotent retry, existing conflicts, two source groups collapsing into a conflicting identity, rollback preserving unrelated items and source data, unsupported preflight, folder identity/isolation/bucket parsing, and signer profile boundaries. The composed-vendor fixture applies both helper integrations after the audited vendor patches and checks signing/cache integration. Swift/macOS/iPhone validation remains separate from portable Python checks.

Primary source references: [LC Keychain hooks](https://github.com/LiveContainer/LiveContainer/blob/3.8.0/LiveContainer/Tweaks/SecItem.m), [LCContainer metadata](https://github.com/LiveContainer/LiveContainer/blob/3.8.0/LiveContainerSwiftUI/Models/LCContainer.swift), [external container import and bucket allocation](https://github.com/LiveContainer/LiveContainer/blob/3.8.0/LiveContainerSwiftUI/Views/AppList/AppSettings/LCAppSettingsView.swift).

Required physical-device checks: update/reinstall LiveContainer through the new build; export signed-in Spotify; attach the exact folder; transfer login; inspect that Spotify opens signed in with settings present; verify native login remains intact. Exercise wrong folder/default container, different team, missing captured permissions, a pre-existing guest credential conflict, protected-item rejection, interruption/retry and recovery before testing offload. No device success is claimed yet. No release publication or build monitoring is authorized by this change.
