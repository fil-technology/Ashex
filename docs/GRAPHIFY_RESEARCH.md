# Graphify Research Notes

Researched on 2026-05-01 from the official repository:

- Repository: https://github.com/safishamsi/graphify
- Package name: `graphifyy`
- Terminal entry point: `graphify`
- Official docs reviewed: `README.md`, `pyproject.toml`, `graphify/__main__.py`, `graphify/skill.md`, and `graphify/serve.py`

## What Graphify Does

Graphify turns a folder of code, docs, papers, images, and optional media into a persistent knowledge graph. The graph is meant to help an AI coding assistant start from project structure and relationships instead of raw search alone.

The official workflow has three broad passes:

- deterministic AST extraction for code files
- optional local transcription for audio/video files
- semantic extraction for docs, papers, images, and transcripts through the hosting AI assistant skill

The merged graph is clustered and exported as machine-readable JSON, interactive HTML, and a plain-language graph report.

## Supported Inputs

Official docs and source indicate support for:

- code files, including Swift, Python, JavaScript/TypeScript, Go, Rust, Java, C/C++, Ruby, C#, Kotlin, Scala, PHP, Dart, Verilog, Lua, Julia, Objective-C, Elixir, Zig, PowerShell, and SQL-related support in newer package metadata
- markdown and text docs
- PDFs when optional dependencies are installed
- office-like docs/spreadsheets when optional dependencies are installed
- images
- audio/video via optional `faster-whisper` and `yt-dlp` transcription support
- URLs through `graphify add <url>`

Graphify also supports `.graphifyignore` with gitignore-like syntax for excluding paths.

## Dependencies

Required runtime dependencies include NetworkX and tree-sitter language packages. Optional extras include:

- `mcp` for an MCP stdio server
- `neo4j` for Neo4j export/push support
- `pypdf` and `html2text` for PDFs/web text
- `watchdog` for watch mode
- `graspologic` for Leiden clustering on supported Python versions
- `python-docx`, `openpyxl`, `faster-whisper`, `yt-dlp`, `matplotlib`, and `openai` in the broader `all` extra on the current main branch

Install guidance should point users to the official repo. Do not hardcode a package-manager command as the only path. The common Python package is `graphifyy`.

## CLI Commands

The current terminal CLI is useful for installed graphs and maintenance, but it is not a complete standalone initial full-build command. The full initial build is primarily implemented as an AI-assistant skill invoked as `/graphify <path>`.

Useful terminal commands exposed by `graphify` include:

- `graphify query "<question>" [--dfs] [--budget N] [--graph path]`
- `graphify path "A" "B" [--graph path]`
- `graphify explain "X" [--graph path]`
- `graphify add <url> [--author Name] [--contributor Name] [--dir path]`
- `graphify watch <path>`
- `graphify update <path>`
- `graphify cluster-only <path>`
- `graphify check-update <path>`
- `graphify benchmark [graph.json]`
- `graphify hook install|uninstall|status`
- platform install commands such as `graphify codex install`, `graphify claude install`, and related uninstall commands

The MCP server is started with Python module execution, for example:

```bash
python -m graphify.serve graphify-out/graph.json
```

It exposes graph tools such as `query_graph`, `get_node`, `get_neighbors`, `get_community`, `god_nodes`, `graph_stats`, and `shortest_path`.

## Output Format And Storage

Graphify writes project-local output under `graphify-out/`.

Important files:

- `graphify-out/GRAPH_REPORT.md`: compact human-readable summary for agent orientation
- `graphify-out/graph.json`: persistent NetworkX node-link graph JSON
- `graphify-out/graph.html`: interactive graph visualization
- `graphify-out/wiki/`: optional agent-crawlable wiki output
- `graphify-out/cache/`: semantic and AST cache data
- `graphify-out/manifest.json`: mtime-based local manifest
- `graphify-out/cost.json`: local token/cost accounting
- `graphify-out/.graphify_python`: interpreter path recorded by the skill workflow
- temporary `.graphify_*` files during extraction/build/update flows

Graphify does not require a graph database. Neo4j export/push is optional.

## Query Behavior

`graphify query` loads `graph.json`, scores nodes by question terms, starts from the top matching nodes, traverses breadth-first by default, and prints a bounded subgraph as text. `--dfs` switches to a depth-first traversal for path-like exploration. `--budget` controls output size.

`graphify path` finds a shortest path between matching node labels.

`graphify explain` prints one matched node plus source, type, community, degree, and its highest-degree neighbors.

ASHEX should keep these outputs bounded before injecting them into model context.

## Incremental Rebuild Behavior

Graphify has two incremental paths:

- `graphify update <path>` re-extracts code files and rebuilds the graph without LLM calls when a graph already exists.
- `graphify watch <path>` watches code changes and auto-rebuilds after debouncing. Docs, papers, and images are marked for semantic re-extraction instead of silently reprocessing through an LLM.

Git hooks can be installed with `graphify hook install`; they rebuild after commits and branch switches for code-only changes.

ASHEX should not present initial full graph generation as a cheap operation. The initial build can invoke AI-assistant semantic extraction and may be expensive for large or media-heavy corpora.

## Swift Integration Options

Recommended ASHEX integration order:

1. Subprocess wrapper for installed CLI commands.
2. Project-local metadata reader/writer for `graphify-out` and `.ashex/graphify/state.json`.
3. Compact graph context provider that reads `GRAPH_REPORT.md`, `graph.json`, and query output.
4. Optional MCP stdio bridge later through ASHEX's existing MCP transport.
5. Optional assistant-skill orchestration for full initial builds only after ASHEX can safely coordinate multi-agent extraction.

## Integration Risks

- Full initial graph building is skill-driven, not a single stable terminal `graphify build` command.
- Semantic extraction can be token-expensive and should be explicit on large corpora.
- `graphify-out/manifest.json` is mtime-based and should normally remain local.
- `graphify-out/cache/` can be useful but may be large.
- Query output can still be too big for prompts unless ASHEX summarizes and bounds it.
- Running `clean` on `graphify-out` is destructive and should require an explicit flag or approval.
- Local watch/hooks may run rebuild code after commits; ASHEX should make this visible before installing hooks.

## ASHEX Command Mapping

Initial safe command mapping:

- `ashex graphify status`: detect executable, version, graph files, report files, state metadata, and next action
- `ashex graphify query`: wrap `graphify query`
- `ashex graphify path`: wrap `graphify path`
- `ashex graphify explain`: wrap `graphify explain`
- `ashex graphify report`: print or locate `GRAPH_REPORT.md`
- `ashex graphify rebuild`: wrap `graphify update <project>` only when a graph exists
- `ashex graphify cluster-only`: wrap `graphify cluster-only <project>` when a graph exists
- `ashex graphify clean`: guarded removal of graph outputs and ASHEX graph metadata
- `ashex graphify build`: verify installation, detect corpus, prepare ignores/state, and print the official `/graphify <path>` full-build instruction until ASHEX owns safe full-build orchestration
