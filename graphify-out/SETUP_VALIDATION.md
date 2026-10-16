# Graphify setup validation — 15 October 2026

- Reused graphify 0.9.91; reviewed requested upstream README and installed integration/update code before configuration.
- Final graph: 11,883 nodes, 27,756 edges, 482 communities. Build commit: `b2439a6cb687f8f45190d55d2edbec09075b46b6`.
- All 78 first-party Swift files under SideKick, SideKickVPN, and Tests have source-backed graph nodes.
- Zero dangling edge endpoints; zero missing referenced source files; zero absolute manifest keys.
- Query/explain/path commands exited successfully. Queries located AppEnvironment, SigningAccountStore, SideStoreOperationService, LocalVPNService, GitHubUpdateService, LiveContainerStore and PacketTunnelProvider. Vendor IdeviceGateway and DeveloperPortalAPI symbols are present.
- Source cross-check: SideStoreOperationService.swift:8–13 retains account/IPA stores; AppEnvironment.swift:93 calls its catalogue loader; DailyRefreshShortcut.swift:78 acquires a VPN lease and creates the operation service at line 82. LocalVPNService.swift:149 defines acquire and line 170 defines release. The undirected graph path links these services through the shortcut. INFERRED links remain hints rather than runtime proof.
- GitHubHistoryClient explain also surfaced its production consumer and regression tests. Queries with small budgets reported truncation; class-level call-only filters may return just the class because calls attach to methods. Use the graph's exact method IDs or file seeds for narrower queries.
- Local hook-check was executed: exit 0, zero output characters. AGENTS.md supplies guidance; no automatic querying was demonstrated or promised.
- No active Git maintenance hooks existed and none were installed. No package installs, upgrades, background network tasks, commits, staging, or vendor edits were performed.
- All pre-existing Git status entries were still present unchanged after setup. New Git ignore rules keep graph.json/report/manifest eligible to commit, while excluding local cache, sidecars, visualization and absolute-path Codex hook configuration.
- Refresh ran successfully after the final guidance changes, reusing cached extraction. Model token cost: 0 input / 0 output.

## Remaining limits

Two vendor Swift files were partially parsed: minimuxer HeartbeatService.swift (line 118) and WirelessPairTargetDialog.swift (line 116). Five inputs produced no symbols, including the forwarding script, the bridging header, and three vendor prose instruction files. 105 paths are unclassified. Workflow YAML is detected but not modeled by the AST update run. Storyboards/XIB, plist/XML, entitlements, xcconfig, and integration patches need direct review. This map describes the current checkout, including existing dirty source, rather than CI's final patched product. Full prose semantics, external library internals, build success, and device behavior are not established.

See ../docs/graphify.md for maintenance and scope. Local graph.html is an aggregated community visualization because the graph exceeds 5,000 nodes.
