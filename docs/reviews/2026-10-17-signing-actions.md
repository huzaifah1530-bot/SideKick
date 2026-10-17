# Signing-action failures, 17 October 2026

Evidence: four supplied screenshots show two distinct failures. Three are different scroll positions of the same LiveContainer re-sign error: IXErrorDomain 2, underlying 8, extension ID equal to the parent ID rather than a child of it. The fourth shows SideKick re-sign failing its post-sign backup-group permission check. No additional reproduction steps or installed build number were supplied.

## LiveContainer extension identifiers

In main-profile mode, extension mappings were keyed by source IDs, but re-sign preparation looked them up using rewritten IDs. A source with an already signed parent or a custom target ID could miss that lookup and fall back to the main profile's bundle ID. Mapping preparation also looked up the profile by the original operation ID instead of the effective target ID.

The repair uses the effective main-profile key, preserves the source extension's child suffix, resolves source IDs before rewritten IDs, and clears mappings between pipeline phases. Prepared bundles are checked for valid, distinct child IDs before signing and installation. Invalid assigned profiles fail with guidance rather than being sent to iOS. Staged copies are changed; retained source bundles and installed records are not reset.

## SideKick backup-group permissions during re-sign

The previous packaging repair preserved the request in new IPAs, but re-sign can use an older retained source without that request. Provisioning and the signer also disagreed: the profile could grant App Groups while the signer filtered out the key absent from the source. Finally, using the active signed ID as the canonical source identity made self-detection inconsistent, and release group adjustment could append a second team suffix.

Source recognition and the backup-group base now also recognize canonical `com.sidekick.app`; the active signed identity and persistent record keys stay unchanged. Both feature provisioning and group assignment use the same effective requests, including the current backup group for the manager app. Existing group IDs are preserved without another team suffix and require the same signing team. A separate installation under a different team requests its own group. The signer accepts explicit manager-only group requests only when every requested group is authorized by its matched profile. Other apps retain their existing entitlement filtering. Post-sign checks remain enabled.

## Verification and limits

Regression coverage composes the patches against pinned upstream revisions. macOS fixtures execute the actual extension mapping, final identifier validation, request normalization, signer filtering, and post-sign guard. Cases include unsigned and already signed sources, custom targets, stale mappings, duplicate IDs, retained sources missing App Groups, unauthorized groups, unrelated apps, and preservation of other requests. The existing packaged-IPA checks remain in the build.

Windows checks cannot verify Apple provisioning or iPhone installation. Device confirmation must re-sign LiveContainer with its retained extensions and re-sign SideKick using the existing account, checking that backup access and app data remain intact. A profile without the required App Group, or a different signing team, cannot be bypassed.
