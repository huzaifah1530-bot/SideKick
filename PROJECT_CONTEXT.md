# SideKick project context

- SideKick is a SwiftUI iOS sideloading app targeting iOS 18. The canonical product build is `.github/workflows/ios-build.yml`, using the patched `Vendor/SideStore/AltStore.xcodeproj` and SideStore runtime bootstrap. Root `project.yml` is an obsolete standalone scaffold, not the shipped product.
- `SideKick/App/AppEnvironment.swift` wires app services and catalogue state; `Views/`, `ViewModels/`, `Components/`, and `DesignSystem/` implement the app experience.
- `SideKick/Services/SideStoreOperationService.swift` adapts the upstream install/refresh pipelines; `SigningAccountStore.swift` manages account-scoped signing sessions. Signing credentials live in the iOS Keychain.
- `SideKick/Services/LocalVPNService.swift` verifies the paired device for each operation. The loopback tunnel comes from the LocalDevVPN app; SideKick ships no VPN extension.
- GitHub history/update services track release and Actions builds; IPA services retain signing sources. LiveContainer guest discovery is separate from the signing/install queue. See README.md and docs/livecontainer-integration.md for behavior and constraints.
- `Vendor/SideStore` and its recursive SideSign/minimuxer submodules are pinned dependencies. CI applies `patches/` and integration scripts; the graph describes checked-out source, not the final patched CI tree. Read vendor AGENTS.md before changing vendor code.
- `Package.swift` defines a selected core library/test suite, not the full iOS app. Release fixtures run with `python -m unittest discover -s Tests/ReleaseManifest -v`; Swift tests and product builds require the appropriate Apple toolchain. Static analysis on Windows does not establish device behavior.
- Distribution licensing/provenance and remaining audit constraints are in THIRD_PARTY_NOTICES.md and README.md. Preserve those constraints.
- The checkout had pre-existing app, vendor, and audit work when Graphify was set up on 15 October 2026. Use current Git status and source rather than treating this note or a graph as a live work ledger.

For graph use, coverage limits, validation evidence, and maintenance, see docs/graphify.md.
