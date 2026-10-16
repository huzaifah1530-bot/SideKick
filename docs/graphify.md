# Persistent Graphify map

## Installation and Codex

Setup on 15 October 2026 reused Graphify 0.9.91, uv 0.13.1, Python 3.14.5, and Git 2.55.0 on Windows. No package upgrade or remote script was needed. The existing user-level Codex skill at `~/.codex/skills/graphify/` matches the installed package. The requested [Graphify repository](https://github.com/blockflix/Graphify) documents the `graphifyy` package (its metadata points to Graphify-Labs/graphify).

On another machine, install using the documented commands after reviewing the current instructions:

```text
uv tool install graphifyy
graphify install --platform codex
graphify codex install
```

The last command was run in this clone after reviewing its implementation. It writes/merges the graphify section in root AGENTS.md and registers a local `.codex/hooks.json` entry. The hook's `hook-check` command intentionally exits successfully with no output. It neither queries nor refreshes the graph. Codex guidance comes from AGENTS.md and the installed skill; automatic query execution is not guaranteed. New Codex sessions must open this repository to load its instructions.

This Windows session does not have the tool bin directory on PATH. Use the checked-in forwarding script; it uses an existing installation and never downloads anything:

```powershell
.\scripts\graphify.ps1 query 'SideStoreOperationService SigningAccountStore' --budget 1500
.\scripts\graphify.ps1 explain 'SideStoreOperationService'
.\scripts\graphify.ps1 path 'SideStoreOperationService' 'LocalVPNService' --undirected
.\scripts\graphify.ps1 update .
```

Run from the repository root. On machines where graphify is on PATH, the ordinary documented commands work directly.

## Scope and persistence

The initial build used `graphify update .`: deterministic local code extraction, structural Markdown/YAML extraction where supported, graph assembly, community detection, and report generation. It used zero model input/output tokens. No semantic model backend or new API key was configured. It is a structural map, not a complete interpretation of prose or runtime behavior.

`.gitignore` remains respected. `.graphifyignore` adds indexing exclusions for archives, credentials, caches, asset/media files, generated packages, copied reference trees, local Codex configuration, and historical audit output. Vendor source remains included. These indexing rules do not change what Git tracks.

Commit candidates: AGENTS.md, PROJECT_CONTEXT.md, this guide, scripts/graphify.ps1, .graphifyignore, .gitignore, and graphify-out/{graph.json,GRAPH_REPORT.md,manifest.json}. Nothing was staged or committed by setup. The graph is approximately 16 MB and changes as a whole on rebuild; review regeneration alongside source changes. The manifest uses relative paths and supports reuse across clones.

The .gitignore additions exclude only Graphify caches, cost/state sidecars, reproducible graph.html, and the installer-created machine-specific .codex/hooks.json. They do not exclude graph.json, GRAPH_REPORT.md, or manifest.json. Hidden community-label state can be regenerated locally. Do not put secrets in graph memory or graph artifacts.

## Refresh and staleness

Run `graphify update .` (or the Windows script) after source edits, branch switches, pulls, merges, submodule changes, and changes to ignore rules. No Git hooks, watchers, pull aliases, merge drivers, or automatic network tasks were installed. This explicit command is the simplest maintenance policy for this checkout.

Compare the report's build commit with `git rev-parse HEAD`, but also inspect `git status --short` and recursive submodule status: equal HEAD does not establish freshness when the working tree or submodules changed. The graph includes the checked-out dirty source at generation time. When uncertain, refresh before relying on a query. `graphify check-update .` currently invokes a rebuild; it is not a read-only freshness check. Do not use `--force` unless source deletion/refactoring explains a rejected graph shrink.

`update` refreshes supported structural code/docs, without semantic model calls. For a richer interpretation of changed prose/media, explicitly use the installed `/graphify --update` skill and review that scope; plain `update` does not promise semantic extraction. Unsupported files still need direct inspection.

The initial graph exceeded the 5,000-node visualization threshold; Graphify generated an aggregated community view at graphify-out/graph.html. It is local and regenerable. To disable visualization on a refresh, set `GRAPHIFY_VIZ_NODE_LIMIT=0` for that command. HTML export may rely on remote browser assets; CLI queries use local graph.json.

## Known coverage limits

- Two vendor Swift files had tree-sitter syntax errors and partial extraction: Dependencies/minimuxer/Sources/Services/HeartbeatService.swift (first error line 118; 22 symbols) and SideStore/Views/Settings/Advanced/PairingFile/WirelessPair/WirelessPairTargetDialog.swift (first error line 116; 16 symbols), both under Vendor/SideStore. These warnings do not establish compiler errors.
- The initial run reported 105 unclassified paths, including XIB/storyboards, XML/plists, entitlements, xcconfig, patch files, and extensionless metadata. Graph relationships cannot replace inspection of CI patch application, provisioning, Core Data schemas, or UI resources.
- Four inputs yielded no symbols: SideBackup-Bridging-Header.h, CERTIFICATE-OF-ORIGIN.md, CLAUDE.md, and GEMINI.md under Vendor/SideStore. Prose semantics and external framework implementations are not fully mapped.
- The forwarding script also yields no symbol nodes because it defines no functions. YAML workflows are detected as documents but are not represented by this AST update run; consult .github/workflows/ios-build.yml directly for build behavior.
- Swift call resolution includes inferred relationships. Common external names can create generic hubs; source verification is required. Queries can truncate results: narrow with exact seeds or raise --budget instead of treating an omitted node as absent.

## Validation

The initial graph contained 11,872 nodes, 27,747 edges, and 452 communities. Actual `query`, `explain`, and `path` calls found SideStoreOperationService, SigningAccountStore, LocalVPNService, and their source locations. The undirected path connected SideStoreOperationService through DailyRefreshShortcut.run and LocalVPNService.acquire; inferred edges are navigation hints, not proof of runtime calls. Final coverage and source checks are recorded in graphify-out/SETUP_VALIDATION.md.
