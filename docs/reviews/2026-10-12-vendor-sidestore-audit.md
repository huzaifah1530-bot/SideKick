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
