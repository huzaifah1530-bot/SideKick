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

