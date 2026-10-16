## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

When the user types `/graphify`, use the installed graphify skill or instructions before doing anything else.

Rules:
- When graphify-out/graph.json exists, run `graphify query "<question>"` before your first grep, search or source-file read for a codebase question, and put this rule in every subagent prompt that explores code. Read raw files only for lines the graph or an earlier read already located. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- Dirty graphify-out/ files are expected after hooks or incremental updates; dirty graph files are not a reason to skip graphify. Only skip graphify if the task is about stale or incorrect graph output, or the user explicitly says not to use it.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
- A committed graphify-out/graph.json is rewritten whole on every build, so a large diff to it in a pull request is expected. Do not flag it as churn or suggest skipping the graph rebuild or its hooks.

### Repository-specific graph guidance

- On Windows when `graphify` is not on PATH, use `.\scripts\graphify.ps1` with the same arguments. It forwards to the existing local installation without downloads.
- Verify graph-derived findings against the referenced source before making changes, especially INFERRED edges. Inspect source directly for unsupported files or missing/truncated query results; the graph is not complete coverage.
- Read PROJECT_CONTEXT.md for the canonical build and subsystem boundaries; docs/graphify.md records setup, limitations, and maintenance.
- Refresh with `graphify update .` after edits, branch switches, pulls, merges, submodule changes, or ignore-rule changes. Compare the report commit to HEAD and inspect dirty source/submodules; matching commits alone do not prove freshness. `check-update` is a rebuild, not a read-only check.
- No Git maintenance hooks are installed. The documented Codex PreToolUse hook is intentionally a no-op; these instructions, not the hook, request graph consultation.
