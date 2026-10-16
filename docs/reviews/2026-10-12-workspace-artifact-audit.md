# Workspace artifact audit — 2026-10-12



Scope: `.build`, `artifacts`, `dist`, `action-logs-20261009124257`, root `action-logs*.zip` and `*.zip` files, and `sidestore-reference`. Git internals were excluded, including `sidestore-reference/.git`. Audit only; no production files or external services changed.



## WA-001 — P3 — Historical distribution package can be mistaken for the current release



**Where:** `dist/SideKick-72500e3/SideKick-unsigned.ipa` and `dist/SideKick-72500e3/SideKick-corresponding-source.tar.gz`.



**What and why:** The IPA identifies version `0.7.0`, build `0700`, and lives under an older commit directory. This is a historical snapshot, not proof that the current integrated build is misversioned: standalone project metadata and patched vendor release metadata already diverge (SK-032). The practical release-flow risk is selecting this local package as current without checking its commit and embedded metadata. Retaining an explicitly named old snapshot is itself legitimate.



**Improve:** Make release selection use an explicit commit/package manifest and validate the IPA metadata against the integrated build configuration. Keep historical snapshots clearly distinguished from a current download/default; do not replace them solely because a newer checkout exists.



## Inventory and review coverage



The coverage JSON records 1,647 non-Git files: 843 `.build` generated outputs (71,095,724 bytes), 13 files under `artifacts` (2,861,177 bytes), 2 files under `dist` (47,293,605 bytes), 11 extracted action-log files (183,310 bytes), 11 extracted failed-run log files, 2 root log ZIPs (68,047 bytes), and 765 reference-tree files (28,701,381 bytes).



All files have recorded paths, byte sizes, and SHA-256 hashes. The 843 `.build` outputs received generated-output inventory/hash review; their contents were not read, except both generated Swift test-runner/anchor files subsequently read in full by the parent reviewer. The 13 `artifacts` files received hash and archive/plist metadata review. Four timestamped artifact ZIPs each contain one IPA; the contained app bundles have no frameworks, extensions, provisioning profiles, or code-signature resource. The later standalone unsigned artifact has 12 IPA entries and version `1.0.0`/build `1`; earlier snapshots have 9 entries, and the first snapshot's app plist lacks bundle/version fields. These are historical build snapshots.



The `dist` IPA was parsed as a ZIP: it contains 186 entries, 7 framework paths and 24 extension paths, has no embedded provisioning profile, and has a `_CodeSignature/CodeResources` resource. This records a resource manifest; no claim is made that the IPA is signed. The corresponding source tarball was decompressed and its tar headers inventoried (1,095 members; 28,672,666 uncompressed member bytes); source member contents were not read.



Both root log archives were enumerated and their complete text members parsed for warning/error/failure lines and common credential patterns. The scan found zero credential-pattern lines. The action-log archive describes a failed Oct. 9 build due to a missing generated `Info.plist` path; the separate `failed-run.zip` shows a Swift immutable-property double initialization in `IPAImportStore`. The extracted action-log directory's 11 files hash-match the corresponding members of its ZIP. These are historical failures; the current project declares generated `Info.plist` output and initializes `fileManager` once. The earlier log also reports missing `SideKickIcon.svg` asset warnings; the current asset catalog references `SideKickIcon-1024.png`, so this warning is not reproduced in the current tree. The `AppIntents` metadata warning is informational.



The 765 `sidestore-reference` files hash-compare against `Vendor/SideStore`: 756 are byte-identical and 9 differ. The parent audit already fully read the 9 variant differences; those contents were not reread here. Differences, verified by SHA-256:



- `Build.xcconfig`

- `AltStore/Info.plist`

- `AltStore/SceneDelegate.swift`

- `AltStore/Intents/App Intents/AppShortcuts.swift`

- `AltStore.xcodeproj/project.pbxproj`

- `SideStore/Core/Operations/PipelineOperations/UpdateAppCertificateOperation.swift`

- `SideStore/Core/Operations/PipelineOperations/VerifyCertificateOperation.swift`

- `SideStore/DeepLinks/URLHandler.swift`

- `SideStore/Views/Settings/Advanced/UserCustomizations/UserCustomizationsView.swift`



The 756 identical files rely on the already completed Vendor source review. Neither group was independently source-read in this artifact pass. No additional actionable finding was confirmed from generated build outputs, historical logs, or reference-only metadata.



Parent reconciliation: all 11 extracted `failed-run` files are exact byte matches of the already parsed ZIP members; their hashes and duplicate review method are now recorded.

