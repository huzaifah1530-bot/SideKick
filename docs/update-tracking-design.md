# Reliable GitHub build tracking

The user requests a rework of unreliable update tracking and requires all work directly on main. Existing installations and credentials must remain intact. No system can infer the exact GitHub artifact installed from an arbitrary IPA whose version labels are reused; uncertainty must be visible rather than treated as current.

Investigated causes: the old comparison reduces rebuilt Actions artifacts to run ID ordering; release keys ignore asset identity/revision; absent baselines and empty downloadable history collapse into no-update results; previously inferred or stale baselines survive external changes; read-modify-save confirmation can race source edits.

Design: identify downloadable files by their GitHub asset/artifact IDs and revision, keep installed-build evidence separate from discovered history, invalidate evidence when the installed observation changes, and expose unknown/not configured/no download/skipped/current/update/error states. Only successful installs or explicit user confirmation establish a baseline. Legacy records require confirmation rather than trusting prior guesses. Source matching is canonical and scope-specific; ambiguous asset filters produce an actionable error. Reading history, downloading, and skipping never advance the installed marker.

The shared actor applies installation confirmations atomically against an expected source. UI saves preserve a concurrently confirmed installation unless the user explicitly edits the baseline. Core policy and API history decoding/pagination are compiled into the production Foundation test package, with injected HTTP transport. Cover reruns, replaced release files, labels reused across builds, expired/missing/ambiguous assets, old configuration JSON, edited source and tokens, external reinstalls, unknown baselines, and download/install distinction.

Published artifacts remain immutable download targets. Guest observations can detect metadata/file changes, but cannot prove externally installed builds with identical observable metadata; guest confirmation stays explicit. Existing signing account and library identity behavior is retained.

API references: https://docs.github.com/en/rest/releases/assets and https://docs.github.com/en/rest/actions/artifacts.
