# Vendor SideStore subtree audit — 2026-10-12

Scope: `Vendor/SideStore/SideStore` (211 source files), with build workflow and SideKick integration patch read for reachability. Audit only; no production files changed. Findings distinguish active engine paths from retained upstream UI.

## VS-001 — P1 — Pairing migration deletes the only pairing record after failed conversion or write

**Where:** `Vendor/SideStore/SideStore/MaintenanceManager.swift:217–228` (`migratePairingFiles`), maintenance completion at lines 82–83; reached from `Vendor/SideStore/AltStore/AppDelegate.swift:194` during boot.

**Why / trigger:** A nonempty legacy `ALTPairingFile.mobiledevicepairing` is parsed with `try?` under each protocol and new files are written with `try?`. The legacy record is then removed unconditionally even if neither parser accepted it or a destination write failed. The maintenance counter is subsequently advanced to 7 regardless of success. A transient write error therefore destroys the only recoverable valid pairing file; a format that this version cannot parse is also lost instead of retained for repair. The next launch cannot retry the migration and users must regenerate their pairing record.

**Suggested fix:** Make conversion and writes throw or return explicit success, verify at least one valid persisted replacement before deleting the legacy file, and advance this maintenance pass only when its required work succeeds. Preserve the original and show an actionable migration failure when conversion is impossible. Validate malformed/nonempty input and simulated destination-write failure.


## VS-002 — P1 — External pairing deep link exports sensitive pairing data without consent and logs it

**Where:** `Vendor/SideStore/SideStore/DeepLinks/URLHandler.swift:78–85` routes `pairing` requests directly to `DeepLinks/ExportPairingFileHandler.swift:13–48`; the full encoded record is logged at line 39. `AltStore/SceneDelegate.swift:26,92` receives incoming URLs; the integration patch preserves this route.

**Why / trigger:** An external app can open `sidekick://pairing?urlname=<its-scheme>` (or the retained SideStore scheme). The handler immediately reads the active pairing record and opens the caller-controlled callback scheme containing its complete base64 value. No confirmation names the receiving app or explains the transfer, unlike certificate export. Base64 is reversible and the complete payload is additionally copied into diagnostic logs. This exposes device pairing credentials through a normal external entry point without an intentional export action and can expose them again when users share logs.

**Suggested fix:** Validate the receiving scheme, require an explicit export confirmation naming the destination and explaining access granted, and never log pairing contents or a callback URL containing them. Prefer a controlled share/document flow; retain callback support only with validated destinations and explicit consent. Test cancellation and assert diagnostic output contains no record payload.


## VS-003 — P2 — Pipeline reports success when installation metadata could not be saved

**Where:** `Vendor/SideStore/SideStore/Core/Operations/PipelineRunner.swift:248–267`, `performOperation`.

**Why / trigger:** The pipeline completes installation/refresh, attempts `dbContext.save()`, catches and logs any persistence error, then unconditionally calls `group.set(.success(result))` and logs SUCCESS. A disk-full or persistent-store failure leaves the app's refreshed expiration/certificate/cache identity absent from durable storage, while the UI and completion callers receive success. After restart users can see stale status or an installed app missing from management, with no repair prompt explaining that the device operation succeeded but tracking failed.

**Suggested fix:** Propagate a distinct persistence failure with the completed device result and offer metadata reconciliation; do not return an unqualified success. Keep the post-install state available for recovery rather than rolling back the device action. Test a successful device operation followed by a failing managed-context save.




## VS-004 — P2 — Batch cellular refresh leaves mobile data off on injection failure

**Where:** `Vendor/SideStore/SideStore/Core/Operations/StandaloneOperations/InjectBatchProfilesOperation.swift:43–67`; called by `Core/Operations/PipelineRunner.swift:209–222`.

**Why / trigger:** The batch operation runs the TurnOffData shortcut, then throws on any profile installation or managed-context save failure. TurnOnData is only called after the complete loop succeeds. The enclosing runner's defer clears progress/background state but does not restore data. This differs from the single-app `RefreshAppOperation`, which restores data in both its success and catch paths. With two or more cellular refreshes, a failed install can therefore leave the user's mobile data disabled after the reported failure.

**Suggested fix:** Guarantee restoration on every exit, including cancellation, using an explicit async cleanup success/catch pattern that runs after the attempted toggle. Test failure during the first profile and during record saving, and verify exactly one restoration attempt.

## VS-005 — P2 — Batch refresh never updates app or extension provisioning expiration

**Where:** `Vendor/SideStore/SideStore/Core/Operations/PipelineOperations/RefreshAppOperation.swift:34–47` queues the batch and returns before `updateInstalledApp`; `StandaloneOperations/InjectBatchProfilesOperation.swift:51–60` updates only certificate status.

**Why / trigger:** Single refresh calls `installedApp.update(provisioningProfile:)` and updates every extension after profile installation. The cellular multi-app path queues raw profile bytes, returns the existing app, and later injects them without applying profile creation/expiration metadata to either app or extensions. A successful batch therefore leaves stale expiry dates in the database and UI, so users can be told apps are expiring even after successful refresh, and subsequent expiration-based refresh scheduling uses stale state.

**Suggested fix:** Carry parsed profile identity/metadata with each pending batch and update the main app and each extension only after their profiles are installed successfully. Reuse the same post-install state update routine as a single refresh. Verify batch and single refresh produce identical persisted dates for a main app with extensions.


## VS-006 — P1 — Every installed third-party app receives the account's private signing key

**Where:** `Vendor/SideStore/SideStore/Core/Operations/PipelineOperations/EmbedSigningCertOperation.swift:38–44`; `Core/Certificates/CertificateManager.swift:49–55,81–86`; invoked unconditionally by normal install/resign step lists in `Core/Operations/OperationStepDefinition.swift:51,74`.

**Why / trigger:** The operation converts the active/override signing certificate to PKCS#12 and writes `ALTCertificate.p12` inside the target app bundle, including ordinary third-party apps. The export password is the certificate serial number (`getPassword`), which is public and retrievable from that same app's code signature or PKCS#12 certificate. Any installed app can therefore read its own bundle and recover the signing private key. Signing an app requires producing a signature, not giving the signed app the signing credential. Sharing/exporting the resigned IPA also distributes this recoverable key. The current integration patch does not restrict this step.

**Suggested fix:** Embed only public DER certificate material in third-party apps. If self-reinstallation needs private signing credentials, restrict PKCS#12 embedding explicitly to the authenticated store app and avoid a password derived from public certificate data; preferably retain private keys only in the manager's Keychain. Check existing exported IPAs and consider certificate rotation for exposed credentials. Validate that a third-party signed bundle contains no private key.


## VS-007 — P1 — Untrusted IPA dependency path can escape its app bundle and overwrite manager data

**Where:** `Vendor/SideStore/SideStore/Core/Operations/StandaloneOperations/DownloadAppOperation.swift:240–280` (`downloadDependencies` and dependency download destination).

**Why / trigger:** An imported app's `AltStore.plist` supplies `ALTDependencies[].path`; the manager downloads its `downloadURL`, appends the raw path to the extracted app bundle, creates parent directories and copies with replacement. No normalization, traversal check, or symlink containment check constrains the destination to the staged app. A crafted dependency path containing `../` components can reach sibling staging or other writable manager-container files. This gives an uninstalled IPA a write primitive in the manager's sandbox before app verification/signing completes. A malicious dependency can replace unrelated app data or configuration rather than merely populate its bundle.

**Suggested fix:** Resolve and normalize the destination against a canonical staged bundle root, reject absolute/traversing paths and symlink escapes, enforce allowed download URL schemes, and copy only after containment is verified. Test `../`, nested traversal, absolute paths and symlink parents against a sibling sentinel file.

## VS-008 — P2 — Compatible-version fallback still downloads the original version URL

**Where:** `Vendor/SideStore/SideStore/Core/Operations/StandaloneOperations/DownloadAppOperation.swift:35,89–120,130–143`.

**Why / trigger:** The initializer stores `sourceURL = app.url`. When the latest source version fails the OS compatibility check, the user can accept a compatible older version and the code calls `download(latestSupportedVersion)`. That method sets `context.appVersion` to the older version but fetches the initializer's original `self.sourceURL`, not the passed version's URL. The user agrees to an older supported build yet receives the newest incompatible IPA, while metadata claims it is the supported version. Later verification may reject it or the wrong version may be installed if its declared deployment metadata differs.

**Suggested fix:** Derive the download URL from the actual selected `app`/`AppVersion` argument at download time. Keep the downloaded URL, release track and version metadata tied to the same selection; test latest and compatible builds with distinct URLs and bytes.




## VS-009 — P2 — Pairing replacement deletes the working record before the new write succeeds

**Where:** `Vendor/SideStore/SideStore/Core/Pairing/PairingFileManager.swift:115–127`, `savePairingFile`; called by `importPairingFile` and the first-party pairing setup importer.

**Why / trigger:** Once the input parses, the manager deletes the existing protocol's pairing file with `try? removeItem`, then writes the replacement atomically. If that write fails (for example disk-full), the caller receives an error but the previously working pairing record has already disappeared. Atomic writes are designed to replace the destination safely; deleting it first defeats that protection. Failed imports can therefore break existing app refresh rather than leave setup unchanged.

**Suggested fix:** Remove the preliminary deletion and rely on atomic replacement; preserve the existing file on any write failure. Test importing into an existing working record with the write forced to fail and verify the original bytes and selected protocol remain usable.


## VS-010 — P2 — Self-app group filtering mutates the array using stale enumeration indices

**Where:** `Vendor/SideStore/SideStore/Core/Operations/PipelineOperations/FetchProvisioningProfilesOperation.swift:328–331`, `updateAppGroups`.

**Why / trigger:** For a store app, the method enumerates `applicationGroups` and removes entries at the enumeration's original indices whenever they contain `AltStore`. Removing an earlier element shifts subsequent elements. With two matching groups, a later removal can target the wrong group or exceed the current array count and crash. This can occur when refreshing a store IPA with multiple legacy groups or custom entitlements; signing setup should report unsupported groups rather than terminate the app.

**Suggested fix:** Filter in one operation (`removeAll(where:)`) or build a retained list instead of deleting by the original enumerated index. Check zero, one and multiple legacy groups interleaved with required groups.




## VS-011 — P2 — Short successful OCSP responses crash the app instead of returning a validation error

**Where:** `Vendor/SideStore/SideStore/Core/Certificates/OCSPValidator.swift:332–354`, `parseOCSPResponse`.

**Why / trigger:** The parser accepts any response longer than five bytes beginning with a sequence and successful response-status tag. If no valid-status byte pattern is found, it constructs `0..<(bytes.count - 20)` without requiring at least twenty bytes. A six-to-nineteen-byte response such as a DER response-status-only sequence therefore forms a range with upper bound below zero, which traps. The preceding `bytes[offset]` accesses also trust the encoded header length without validating it. These bytes come from a network OCSP response; malformed or truncated successful HTTP responses should be rejected, not terminate a refresh and the app.

**Suggested fix:** Use a bounded DER parser, check lengths before every indexed field/range, and return a structured invalid-response status for missing response bytes. Test responses of lengths 0–20 and oversized ASN.1 length headers.

## VS-012 — P1 — OCSP certificate state trusts unauthenticated byte patterns in an HTTP response

**Where:** `Vendor/SideStore/SideStore/Core/Certificates/OCSPValidator.swift:186–206,332–357`; `PipelineOperations/VerifyCertificateOperation.swift:124–145` turns this status into stored certificate validity/revocation.

**Why / trigger:** Direct live OCSP uses HTTP, then scans arbitrary response bytes for generic status patterns. It never verifies the BasicOCSPResponse signature/responder authority, requested certificate serial/issuer hash, or freshness timestamps. A proxy or modified HTTP response can therefore supply a valid/revoked-looking byte pattern for any requested certificate. A signed OCSP protocol can safely operate over HTTP only when its signed payload and identity are validated; this implementation provides neither check, while `.revoked` blocks operations and generic `.valid` marks the certificate usable.

**Suggested fix:** Use Security framework trust/revocation evaluation as the authority or a complete OCSP verifier checking signer authority, CertID and thisUpdate/nextUpdate. Treat uncertain network results as unknown rather than authoritative valid or revoked. Test a wrong-serial response, an invalid signature and an expired signed response.


## VS-013 — P2 — SideJIT URL resolution silently drops HTTPS and custom URL paths

**Where:** `Vendor/SideStore/SideStore/Core/JIT/SideJITManager.swift:43–105`, `resolveAddressIfNeeded`.

**Why / trigger:** A configured server URL is parsed, but every direct-IP, hostname and DNS fallback reconstructs only `http://host:port`. The original scheme, path and other URL components are discarded, with port 8080 even for an HTTPS URL without an explicit port. A user entering `https://jit.example/server` is therefore sent to `http://jit.example:8080` instead. HTTPS-only and reverse-proxy configurations fail, and an explicit transport choice is downgraded while device UDID and bundle identifiers are later sent to that server.

**Suggested fix:** Preserve URLComponents scheme, explicit/default port and base path while replacing only the resolved host; bracket IPv6 addresses correctly and preserve necessary interface scopes. Add deterministic checks for HTTPS with omitted port, a prefixed base path, IPv4 and IPv6.


## VS-014 — P2 — Embedded certificate fallback returns a certificate with the wrong serial

**Where:** `Vendor/SideStore/SideStore/Core/Certificates/CertificateManager.swift:273–307` (`loadEmbeddedCertificate`); consumed by `Core/Profiles/ProfileManager.swift:119–146,163–191`.

**Why / trigger:** Every successful decrypt assigns `signableCert`, even when its serial does not match the requested serial. After trying the passwords, the method returns that mismatching certificate whenever any decrypt succeeded. The profile manager treats a non-nil fallback as a matching private key and reports the profile ready to sign. A profile for certificate B can therefore be labeled signable and paired with the embedded private key for certificate A, leading to signing or installation failure and misleading certificate setup status.

**Suggested fix:** Return a certificate only if its normalized serial (or exact certificate data) matches the requested identity; only an explicitly empty identity may request the default embedded certificate. Test a decryptable embedded certificate whose serial differs from the requested profile certificate.


## VS-015 — P1 (retained tvOS code; excluded from current iOS build) — Web upload trusts filename paths and can overwrite files outside tmp

**Where:** `Vendor/SideStore/SideStore/Core/tvOS/TVWebFileTransferManager.swift:278–314`, `processUploadedBody`.

**Why / trigger:** Multipart `filename` is accepted verbatim, appended to the manager temporary directory and written with replacement semantics. The LAN server has no session token or peer authentication. A crafted HTTP upload with `filename="../Library/..."` can escape tmp and overwrite a writable manager-container file. Accepted extensions are only placed in the HTML input's `accept` hint; the server does not enforce them. This is a real defect in the retained tvOS implementation, but `#if os(tvOS)` excludes it from SideKick's current iOS build.

**Suggested fix:** Reduce filenames to a sanitized basename, use a unique per-transfer directory, verify canonical containment, enforce server-side file types and upload size, and require a short-lived transfer token. Test traversal filenames and unsupported extensions. Keep this finding separated from active iOS release blockers.


## VS-016 — P2 — Markdown mutations mix character and UTF-16 lengths, corrupting emoji links

**Where:** `Vendor/SideStore/SideStore/Extensions/NSAttributedString+Markdown.swift:191–204,509–516`, inline-link replacement and paragraph serialization.

**Why / trigger:** The parser scans NSString ranges in UTF-16 units, then updates `mutationOffset` using `replacementString.count` (Swift grapheme count). A link label such as an emoji occupies two or more UTF-16 units but one Swift Character. After replacing `[😀](https://example.com)`, subsequent marker positions are calculated too far left and can delete part of the emoji or target an invalid range. Paragraph export likewise uses `component.count` for NSRange location/length. This affects any caller supplying markdown with emoji or combining characters; a retained upstream App IDs header calls this renderer. Current SideKick home-screen reachability is not established for this renderer.

**Suggested fix:** Use NSString length or `utf16.count` consistently for all NSRange offsets, or maintain native String.Index positions throughout. Test emoji and combining-mark link labels followed by emphasis and multiple paragraphs; verify both rendering and round-trip serialization preserve text.




## VS-017 — P2 — Cancel on the app-group correction dialog continues the installation

**Where:** `Vendor/SideStore/SideStore/Handlers/PipelineHandler.swift:471–475`, `resolveAppGroupMismatch`; `PipelineOperations/FetchProvisioningProfilesOperation.swift:435–445` consumes the result.

**Why / trigger:** The correction dialog offers Correct & Proceed, Keep Original and Cancel. Both Keep Original and Cancel resume with `.keepOriginal(originalGroup)`. The caller then continues group registration/signing; no cancellation error is thrown. A user who backs out of an identifier discrepancy can therefore still trigger the install using a group they declined to resolve. Other customization dialogs correctly map Cancel to `OperationError.cancelled`, making this inconsistent and unsafe for user intent.

**Suggested fix:** Resume the throwing continuation with `OperationError.cancelled` for Cancel, or introduce an explicit cancellation case and propagate it. Verify no portal mutation or signing step occurs after cancellation.


## VS-018 — P1 — Payload cache identity hashes filenames and sizes, not file contents

**Where:** `Vendor/SideStore/SideStore/Utils/common/AppBundleFingerprint.swift:34–37`; reused by `Core/Operations/PipelineOperations/CacheAppOperation.swift:38–52` and maintenance migration.

**Why / trigger:** Each leaf hash covers only `name|size`, so two bundles with identical directory layout and file lengths but different executable/resource bytes have exactly the same fingerprint. `CacheAppOperation` treats a matching fingerprint directory as an already cached payload and skips copying. A newly verified update can install correctly on that attempt yet its database fingerprint points to the older cached executable; later resign/reinstall/backup operations stage the old payload. Equal-sized metadata changes are also lost, and different apps with the same layout/sizes can share incorrect cached code. A cryptographic outer hash does not fix missing content in its inputs.

**Suggested fix:** Hash file bytes as well as relative paths using streaming reads; define intentional exclusions explicitly and fail rather than omit unreadable children. Version or migrate the cache identity so existing metadata-only fingerprints cannot alias the new format. Verify that a one-byte equal-length change produces a different key and that re-sign stages the updated executable.


## VS-019 — P2 — Invalid certificate in an account backup clears the existing working account first

**Where:** `Vendor/SideStore/SideStore/Utils/importexport/ImportExport.swift:114–136`, `importAccount`; debug JSON import repeats the ordering at lines 281–294.

**Why / trigger:** After decryption/JSON decode succeeds, the importer immediately signs out (clearing active certificate and sign-in state), writes incoming email/password/anisette fields, and only then parses/imports the backup's certificate. A malformed certificate, bad certificate password or certificate persistence failure throws after the previous account was erased. The broad catch also labels such failures as an incorrect password/corrupt backup, obscuring that state was partially replaced. Users trying an invalid backup can lose a previously working setup instead of getting a harmless validation error.

**Suggested fix:** Fully validate backup version, account fields and certificate/private key before mutating any existing state; then apply as a transaction with rollback or a staged credential set. Preserve underlying error distinctions and test a decryptable backup with invalid certificate data against an existing signed-in account.


## VS-020 — P2 — Console capture crashes when its log file cannot be created

**Where:** `Vendor/SideStore/SideStore/Utils/iostreams/ConsoleLog.swift:50,136–138`, lazy `consoleLogger` and log-directory creation.

**Why / trigger:** Log capture force-unwraps `createLogFileHandle()` and log directory creation uses `try!`. If Documents/ConsoleLogs creation or file open fails (for example low storage or a conflicting file at that directory path), launching capture terminates the app. Logging is auxiliary functionality and should never prevent boot or recovery from the storage error it needs to describe.

**Suggested fix:** Make capture initialization failable and fall back to system/original console output when the file destination is unavailable. Return an actionable diagnostic state without crashing; test directory creation and FileHandle-open failure.


## VS-021 — P2 — Entitlement customization silently drops values it cannot represent

**Where:** `Vendor/SideStore/SideStore/Views/Components/EntitlementsCustomizationViewModel.swift:90–110,327–367`; active customization route `Core/Operations/PipelineOperations/UserCustomizationOperation.swift:149–203` and `Handlers/PipelineHandler.swift:308–319`.

**Why / trigger:** The editor only parses Boolean, string, string-array and NSNumber entries. Dictionary, Data and arrays of other plist values disappear from the editor. Proceed reconstructs the entire dictionary from those entries, preserving only the two identity keys from the original. Thus opening customization and proceeding without changes drops other original entitlements even on paid teams, where `isEntitlementAllowed` permits them. The returned replacement is persisted into the signing context, so this is destructive normalization of signing configuration rather than merely a hidden row.

**Suggested fix:** Preserve untouched values of every supported plist type, using a read-only/raw editor for types the form cannot edit. Show any policy-driven removals before proceeding. Verify a round trip containing nested dictionary/Data/heterogeneous-array values retains them when no changes were requested.

## VS-022 — P3 — Array entitlement editors share a single draft input across rows and targets

**Where:** `Vendor/SideStore/SideStore/Views/Components/EntitlementsCustomizationCoreView.swift:511–525`; `EntitlementsCustomizationViewModel.swift:78,113–135,248–254`.

**Why / trigger:** Every array row binds its Add item field to the same `newArrayItemText`. Typing a group ID in the application-groups row makes it appear in every other array row and enables all their Add buttons. Pressing another row's button adds that group ID to the wrong entitlement and clears every row's draft. Target switching also keeps this draft, making an app draft appear on an extension. These are independently labeled inputs and their state should be independent; incorrect keychain/application-group values can then reach signing.

**Suggested fix:** Store draft text by target and entry ID, or keep it in each row's state. Clear only the draft committed by that row, and preserve or explicitly discard drafts on target changes. Verify two array rows can hold distinct pending values.


## VS-023 — P2 — Deleting a raw Info.plist key leaves it in the generated app

**Where:** `Vendor/SideStore/SideStore/Views/Components/InfoPlistCustomizationCoreView.swift:831–833,964–1030`, raw-key trash action and `serialize`; reached through the install customization handler.

**Why / trigger:** Trash removes the entry from `rawEntries`, so the form visibly confirms the key is gone. Serialization starts with the entire original plist and only overwrites remaining entries; it never removes keys deleted from the draft. For any original raw key, proceeding restores its original value in the returned plist. For example removing a usage-description/custom configuration key does not alter the installed app. This makes the editor's delete action unreliable and makes a subsequent audit of requested metadata edits misleading.

**Suggested fix:** Track deleted original keys per target and remove them from the original before applying remaining entries, or reconstruct editable scalar keys while preserving only the unsupported complex values. Verify deleting, editing and adding a key together produces exactly those changes for both main app and extension.




## VS-024 — P2 — Clear Private Key reports success while an active key remains available

**Where:** `Vendor/SideStore/SideStore/Views/Settings/Advanced/Certificates/CertificatesViewModel.swift:657–662`, `clearPrivateKey`; `Core/Certificates/CertificateManager.swift:159–166,185–187,260–266`.

**Why / trigger:** Clear Private Key overwrites the imported certificate slot with public DER and announces that the locally stored private key was removed. It leaves `CertificateManager.activeCertificate` and its separate active signing-key storage intact. `getLocalCertificate` returns this active private key before reading the overwritten slot, so the refreshed screen still reports a private key and signing can continue using it. The UI does not disallow clearing the active certificate, and embedded-certificate fallback can also make cleared keys available again. A user requesting key removal cannot rely on the success message.

**Suggested fix:** Define the clear action's scope explicitly. When clearing the active certificate, remove/deactivate the active signing copy too; account for any embedded fallback and explain if it cannot be erased from the installed bundle. Verify the post-action key lookup and signing state before reporting success.




## VS-025 — P2 — App ID group editor treats every team group as an existing association

**Where:** `Vendor/SideStore/SideStore/Views/Settings/Advanced/DeveloperServices/AppIDs/AppIDDetailView.swift:181–191`, `initializeSelectedGroups`, with Save Group Associations at lines 121–134.

**Why / trigger:** Initialization checks only whether the App Groups capability key exists, then selects every group in `viewModel.appGroups`. A capability flag does not identify which groups belong to this App ID, and the feature value is not even checked. For a team containing groups A/B/C where the app belongs only to A, the UI falsely marks A/B/C associated. Toggling one row and saving submits all remaining team groups, unintentionally broadening/changing associations. This retained developer-portal UI must obtain the actual association list before exposing a destructive replacement save.

**Suggested fix:** Fetch the groups associated with this App ID and initialize selections from that list. Keep association editing disabled while loading or on fetch failure. Verify an app associated only with A displays only A selected, and adding B submits A/B without unrelated C.


## VS-026 — P2 — Editing a portal profile replaces its certificate set with all team certificates

**Where:** `Vendor/SideStore/SideStore/Views/Settings/Advanced/DeveloperServices/Profiles/ProfilePortalDetailView.swift:316–318,221–231`.

**Why / trigger:** On appearance, the editor initializes selected certificates from every team certificate rather than the certificates currently authorized by this profile. Saving even a simple name change regenerates the profile with that invented set. A profile intentionally limited to one signing certificate is thus broadened to unrelated certificates or rejected for incompatible certificate types. The Associated Certificates heading presents these defaults as actual existing associations.

**Suggested fix:** Download/query this profile's existing certificate associations and map exact portal IDs to the selection. Keep loading/error state separate from an empty association. Verify a name-only edit preserves the profile's original certificate and device sets.

## VS-027 — P2 — Portal profile editor cannot save certificate-only edits or device-free profiles

**Where:** `Vendor/SideStore/SideStore/Views/Settings/Advanced/DeveloperServices/Profiles/ProfilePortalDetailView.swift:30–46,218–249`.

**Why / trigger:** `hasChanges` compares only name, app ID and devices, so changing certificate selections alone never displays Save Changes. Separately `canSave` always requires a device selection, including profile types whose `acceptedDeviceTypes` are none (the create-profile form correctly supports that case). A user replacing a certificate must make an unrelated edit to reveal Save, and editing a device-free distribution profile is blocked unless unrelated device IDs are supplied.

**Suggested fix:** Compare certificate selections against the true original certificate set when computing changes, and derive the device requirement from `profile.profileType.acceptedDeviceTypes`. Verify certificate-only updates and name-only changes to a device-free profile can be submitted without unrelated modifications.


## VS-028 — P2 — A previous Bonjour resolution can populate and cancel a newer service's details

**Where:** `Vendor/SideStore/SideStore/Core/Bonjour/BonjourDiscoveryManager.swift:314–323,473–518,521–529`; details view consumes global result in `Views/Settings/Advanced/NetworkDiscovery/BonjourDiscoveryView.swift:711–719`.

**Why / trigger:** Finishing a resolution starts an untracked detached DNS task. Stopping/changing service cancels only connection, NetService and timeout, not this task. Its final guard checks only `isResolving` and an empty result. If the user opens service A then quickly switches to B while A's DNS work runs, B sets those same flags; A's late task passes, publishes A's addresses under B's detail screen, then stops B's live resolution. The result must be associated with the specific request identity.

**Suggested fix:** Assign a generation/request token to each resolve and check it in every callback and final publish. Cancel tracked DNS work where possible and reject stale results regardless. Verify delayed A resolution cannot replace B's result or stop B's request.

## VS-029 — P2 — Re-resolving the same Bonjour service cannot publish updated addresses

**Where:** `Vendor/SideStore/SideStore/Core/Bonjour/BonjourDiscoveryManager.swift:318–320,503–504`; `Views/Settings/Advanced/NetworkDiscovery/BonjourDiscoveryViewModel.swift:460–474,490–492`.

**Why / trigger:** The auto-refresh/manual path calls `resolveService` with `clearExisting` false. For the same service name, its previous `resolvedService` is retained, but `finishResolution` only publishes when that property is nil. Therefore an already resolved service never receives its newly resolved IP/port/TXT data, despite recurring refreshes and successful network callbacks. Two distinct services with the same name in different type/domain scopes also retain the wrong prior result because only name is compared.

**Suggested fix:** Keep the old display while refreshing, but allow the current request to replace it when it completes. Compare full service identity, not just name, and combine with generation validation for VS-028. Verify changing an advertised IP/TXT value appears after manual and periodic refresh.


## VS-030 — P2 — Server interface selection is displayed but never affects advertising

**Where:** `Vendor/SideStore/SideStore/Views/Settings/Advanced/PairingFile/WirelessPair/WirelessPairViewModel.swift:198–210,297–315,487–503`; `WirelessPairTargetDialog.swift:124`.

**Why / trigger:** The dialog lets the user choose an interface and the view model logs the selected ID on confirmation, but `startPairing()` does not receive or read that ID. It invokes `wirelessPairing.start` with only a documents path and filename resolver, so choosing Wi-Fi, VPN, or another interface has no effect on the listener. The UI suggests a network restriction that the underlying API does not implement; users may expose the pairing endpoint on all interfaces or select a network believing the endpoint is reachable there.

**Suggested fix:** Remove interface selection until the pairing API supports binding, or clearly label that advertising listens on all interfaces. If binding is supported, pass and enforce the selected address. Verify choosing each option changes the bound endpoint or that the UI explains the all-interface behavior.


## VS-031 — P3 — A denied security-scoped profile import fails silently

**Where:** `Vendor/SideStore/SideStore/Views/Settings/Advanced/Profiles/ProfileManagementView.swift:220–229`.

**Why / trigger:** When Files returns a profile URL but `startAccessingSecurityScopedResource()` returns false, the callback returns without a message. The importer closes and nothing explains why no profile appeared, while other parsing/import failures in the same flow produce a toast. The user cannot distinguish a permission failure from a successful no-op.

**Suggested fix:** Surface a concise access error and leave the profile list unchanged. Verify denied access produces visible feedback and successful access still releases the scope with `defer`.


## VS-032 — P2 — SideSign raw JSON view stays stale while interactive fields change

**Where:** `Vendor/SideStore/SideStore/Views/Settings/Advanced/UserCustomizations/SideSign/SideSignConfigurationView.swift:64–93,183–191,306–323`.

**Why / trigger:** `rawEditableJSON` is refreshed only during load, save, and reset. Editing any interactive field and switching to Raw JSON before saving shows the previous configuration, not the current draft. Saving that visible JSON can overwrite the form edits with stale values, and the segmented picker gives no indication that the two modes have diverged.

**Suggested fix:** Regenerate JSON when entering raw mode from interactive state, or keep one parsed draft as the source of truth and make unsaved changes explicit. Verify edits survive switching both directions and cannot be silently replaced by stale JSON.


## VS-033 — P2 — Portal lookup failures are presented as missing device registration

**Where:** `Vendor/SideStore/SideStore/Views/Settings/Auth/AccountVerificationRow.swift:175–193,196–228`.

**Why / trigger:** Any error fetching the team's portal devices falls through to `.actionRequired(...deviceUnregistered: true)`, exactly like a successful lookup proving the device absent. The row then tells users device registration is pending and offers a registration flow even when the real cause is network, authentication, or portal failure. Repeated transient failures can prompt unnecessary registration attempts and obscure the actionable error.

**Suggested fix:** Model verification failure separately from a confirmed missing device, show retry/error feedback, and offer registration only after a successful lookup proves absence. Verify offline and portal-error responses never claim the device is unregistered.


## VS-034 — P2 — Export Database creates a file then discards the only URL

**Where:** `Vendor/SideStore/SideStore/Views/Settings/Diagnostics/DeveloperOptionsView.swift:228–245,812–830`.

**Why / trigger:** The Export Database action awaits `CoreDataHelper.exportCoreDataStore()` and logs the returned URL, then drops it. There is no document exporter, share sheet, or visible location feedback. The spinner ends and the user has no way to retrieve the database they asked to export; the utility may consume temporary storage without delivering an artifact.

**Suggested fix:** Present the exported URL through the platform's export/share flow and report errors to the user. Verify the exported file can be saved or shared on supported platforms.


## VS-035 — P2 — An empty search result hides the search field and traps the query

**Where:** `Vendor/SideStore/SideStore/Views/Settings/TechyThings/StorageExplorer/DirectoryExplorerView.swift:62–100`.

**Why / trigger:** The view switches from the list to an “Empty Directory” screen whenever `filteredAndSortedItems` is empty. The searchable modifier exists only on the List branch. If a nonempty folder search has zero matches, the search control disappears while `searchText` remains set; users see a message that the directory itself is empty and cannot clear the query from this screen.

**Suggested fix:** Keep the list/search container present for nonempty directories and show a dedicated “No matching items” empty state with a clear-search action. Verify zero-match searches remain editable and return the original rows when cleared.


## VS-036 — P2 — Failed conflict-resolution copies are silently dropped

**Where:** `Vendor/SideStore/SideStore/Views/Settings/TechyThings/StorageExplorer/StorageExplorerViewModel.swift:465–487`.

**Why / trigger:** After the user supplies a new name for a paste conflict, `copyItem` failures are only written to debug logs. The conflict is removed and the next item is shown, so the flow can appear successful even though the requested file was not copied. This is especially confusing for permission or storage failures because the original conflict dialog vanishes without a result.

**Suggested fix:** Keep the failed conflict active for retry or show an actionable error before advancing. Verify an injected copy failure is visible and does not lose the source item from the pending queue.


## VS-037 — P2 — Cached widget icons never refresh for an existing bundle ID

**Where:** `Vendor/SideStore/SideStore/Widget/WidgetData/WidgetDataManager.swift:88–99`.

**Why / trigger:** `cacheIcon` writes an icon only when `<bundleID>.png` does not already exist. Later publishes for the same app skip the new image indefinitely, so app icon changes and newly customized icons remain stale in widget/Top Shelf snapshots even though the data is republished.

**Suggested fix:** Replace the cached image atomically when the source icon changes, or compare a content/version key before skipping the write. Verify a second publish for the same bundle ID updates the rendered icon.


## VS-038 — P2 — Failed profile downloads are hidden while portal refresh reports success

**Where:** `Vendor/SideStore/SideStore/Views/Settings/Advanced/Profiles/ProfileManagementViewModel.swift:78–100`.

**Why / trigger:** A portal profile absent from local storage is downloaded and imported through nested `try?` calls. If either step fails, the loop continues and the refresh still sets `hasFetchedRemote = true`, clears loading, and reports no error. The management list only renders local profiles, so that portal profile silently disappears from the screen even though the refresh completed.

**Suggested fix:** Collect download/import failures and surface which profiles could not be cached, while retaining portal metadata so they can be retried. Verify a failed download is visible as an error or retryable entry rather than a successful empty refresh.

