# SideSign dependency audit — 12 October 2026

Scope: every file in Vendor/SideStore/Dependencies/SideSign. Full text reads are recorded in the separate SideSign coverage ledger. CLI-only findings are labelled separately from the library integrated into SideKick. No production changes.

### SS-001 — P1: Downloaded Anisette libraries are extracted even after a checksum mismatch

**Where:** `Vendor/SideStore/Dependencies/SideSign/Sources/Anisette/AnisetteDataManager.swift:629–645`.

**What:** When supplied SHA-256 differs from the downloaded payload, the manager only logs “Proceeding with extraction” and unzips/loads the package. The matching sha256Mismatch error type exists but is not thrown here.

**Why:** Integrity validation and actual flow clash: modified/damaged native libraries are accepted despite explicit evidence they are not the expected payload. The later file-existence check does not validate content.

**Improve:** Reject the mismatch before writing/extracting, retain the previous working library set, and surface a concise retry/source error. Stage and validate the complete package before promoting it to the active cache.

### SS-002 — P2: Concurrent library-cache callers can return success after another request failed

**Where:** `Vendor/SideStore/Dependencies/SideSign/Sources/Anisette/AnisetteDataManager.swift:235–258,612–620,690–708`.

**What:** This unchecked-Sendable singleton has unsynchronized mutable isCaching, localProvider and remoteCache. If isCaching is true, downloadAndCacheLibs waits for it to become false and returns without checking that the other operation succeeded or even targeted the same directory/source. Errors are not shared with waiters.

**Why:** A waiting setup can look successful despite no usable libraries, or reuse a provider created for different request context. Concurrent calls also race on the unsynchronized cache state.

**Improve:** Actor-isolate the manager and coalesce requests with an owned Task keyed by source/target settings; await its actual result and revalidate the requested library set. Scope provider caching to the directory/provisioning/client identity it represents.

### SS-003 — P1: ZIP extraction does not enforce destination containment

**Where:** `Vendor/SideStore/Dependencies/SideSign/Sources/Archiver/FileManagerZip.swift:28–60`; `Sources/Anisette/AnisetteDataManager.swift:642`.

**What:** unzipArchive appends the archive-supplied filename directly to the destination, creates its parents and writes the file. It never rejects traversal components, absolute/escaped paths, symlink ancestors or resolved paths outside the extraction root.

**Why:** A crafted archive can overwrite other writable app files instead of remaining inside its staging/cache directory. The same routine handles downloaded native Anisette libraries and app-bundle extraction.

**Improve:** Validate every canonical destination against an owned extraction root, reject escaping/absolute paths and symlink traversal, bound sizes/entry counts, and stage extraction before promotion. Apply checks in the shared routine rather than only a UI importer.

### SS-004 — P2: ZIP readers accept incomplete catalogues and writers can trap at format limits

**Where:** `Vendor/SideStore/Dependencies/SideSign/Sources/Archiver/Archive.swift:290–323,430,481,537,544–555`.

**What:** Central-directory parsing breaks and returns the entries parsed so far on a truncated header, wrong magic or short filename. Writer converts data/file-name/entry-count/offset values directly to UInt32/UInt16 without bounds checks or ZIP64 support.

**Why:** A damaged archive can look like a successful partial extraction. A large app or a bundle with more than 65,535 entries can trap during ordinary packaging instead of returning a recoverable error. Full-entry allocation also amplifies memory pressure for large files.

**Improve:** Reject any catalogue shorter than its declared records, validate local/central lengths consistently, and explicitly reject unsupported ZIP64/oversized values with actionable errors or implement the format. Stream file data where practical.

### SS-005 — P2: App ZIP creation suppresses finalization errors and deletes the previous output first

**Where:** `Vendor/SideStore/Dependencies/SideSign/Sources/Archiver/FileManagerZip.swift:129–171`; `Sources/Archiver/Archive.swift:363–366,512–560`.

**What:** zipAppBundle returns without calling writer.close; deinit performs try? close. Failure to write/synchronize the central directory is discarded. Existing output is removed before the replacement has been built. The sibling zipDirectory explicitly closes and propagates errors.

**Why:** Packaging can report success with a corrupt IPA, and a failed replacement can leave no previous usable export. Two nearly identical packaging APIs have different failure contracts.

**Improve:** Close explicitly before success, build to a temporary sibling and atomically replace the final IPA only after finalization succeeds. Share that finalization/ownership path between packaging APIs.

### SS-006 — P2: Legacy PKCS#12 detection mistakes any ASN.1 sequence for a certificate/key archive

**Where:** `Vendor/SideStore/Dependencies/SideSign/Sources/Compatibility.swift:154–157`; `Sources/Certificates/CertificateParser.swift:13–17`.

**What:** Data.isPKCS12 checks only whether the first parsed TLV has sequence tag 0x30, a tag also used by ordinary DER certificates and other ASN.1 structures. extractDER accepts a boundaryKeyword but never uses it when decoding PEM.

**Why:** The compatibility helper's name promises format identification while it only recognizes a general container, and the boundary selector is misleading. Callers can enter the wrong parser or accept the wrong PEM block and produce confusing import failures.

**Improve:** Validate the PKCS#12 PFX schema/version before classification, and honor/validate PEM block boundaries or remove the unused argument. Keep format errors distinct from a missing private key.

### SS-007 — P1: Authentication explicitly writes the unredacted session token to verbose logs

**Where:** `Vendor/SideStore/Dependencies/SideSign/Sources/DeveloperPortal/Authentication.swift:179–187`.

**What:** After decrypting the authentication result, the code interpolates idmsToken directly into verboseLog. Several error branches also package complete decrypted dictionaries as error payloads.

**Why:** Enabling diagnostic logging can persist credential material alongside normal troubleshooting messages. This conflicts with secure account storage and makes sharing logs hazardous. Exact downstream log/error rendering is checked separately; this line itself supplies the secret unredacted.

**Improve:** Log only stage/status and a non-secret correlation ID. Redact tokens/passwords/provisioning blobs in every payload before logging or including it in a user-visible error.


## SS-008 — Failed HTTP operations can be reported as successful deletions (P2, clashing success/error handling)

**Where:** `Vendor/SideStore/Dependencies/SideSign/Sources/DeveloperPortal/DeveloperPortalAPI.swift:352–360, 464–475, 500–505`.

**What and why:** Neither request dispatcher requires a successful HTTP status before accepting an empty response. In the services dispatcher, any DELETE with an empty body returns `EmptyResponse`, including HTTP 401/403/500. Its decoding catch also returns success for a DELETE whose error body cannot decode to the requested type. The plist dispatcher likewise accepts an empty body whenever the requested type is `EmptyResponse`, regardless of status. Device/profile deletion functions then return `true`. An expired session or server failure can therefore appear to have removed a portal object even though it remains, encouraging retries and leaving local and remote state inconsistent.

**Improve:** Validate HTTP success before applying the successful-empty-response exception. Preserve status and decoded server error in failures; only accept no content for successful responses. Cover failed empty-body DELETE and malformed error-body DELETE when fixing this.

## SS-009 — App ID serialization drops capability state (P2, clashing model contract)

**Where:** `Vendor/SideStore/Dependencies/SideSign/Sources/Models/AppID.swift:17–18, 39–70`.

**What and why:** The public Codable model decodes `features` but never encodes it, and its `entitlements` property is excluded from both coding keys and decoding (always reset to an empty dictionary). Encoding and decoding an AppID silently loses capability data even when the caller expects a complete model snapshot. This is a library contract defect; the active app impact depends on which callers persist this public type, rather than proof that every install is affected.

**Improve:** Separate portal request DTOs from persisted models, or preserve every modeled field in Codable. Add a round-trip check with nonempty features and entitlements when correcting the contract.

## SS-010 — Server errors expose raw response payloads as user messages (P2, inconvenient messages)

**Where:** `Vendor/SideStore/Dependencies/SideSign/Sources/Models/Errors.swift:73–95`; producers `Sources/DeveloperPortal/DeveloperPortalAPI.swift:392–394, 506–508`.

**What and why:** `ServerError.errorDescription` includes the entire raw server payload, JSON/XML body, or missing internal key. Callers presenting localized errors can display a long HTML gateway page or technical authentication response directly to users. It also duplicates the raw body already printed to diagnostics, making ordinary error UI harder to understand and increasing accidental exposure of response data. This is the dependency's message contract; presentation varies by caller.

**Improve:** Give users a short explanation and recovery action (retry, reconnect account, or inspect details). Retain a bounded, redacted diagnostic body in a separate details/log channel instead of embedding it in every localized error.

## SS-011 — Unused authentication DTOs duplicate the live dictionary protocol and drift from it (P3, dead/duplicate/clashing code)

**Where:** `Vendor/SideStore/Dependencies/SideSign/Sources/DeveloperPortal/AuthModels.swift:11–125`; active dictionary protocol in `Authentication.swift:68,121,135` and `AppGroups.swift:80`.

**What and why:** Repository-wide Swift reference searches find these request/response types only in their declarations and relationships inside AuthModels.swift. Authentication and group assignment instead build dictionaries directly. The unused Codable response/request types already use lowercase `b`, `m1`, and `m2`, while the live protocol reads `B`/`M2` and sends `M1`. Reusing the apparently authoritative typed model would encode/decode a different protocol. They are unused in this checkout, not proven removable for all external clients of the public library.

**Improve:** Either migrate the live implementation to tested DTOs with exact CodingKeys and one protocol definition, or deprecate/remove the unused models with a public API compatibility decision. Avoid maintaining a second misleading schema.
