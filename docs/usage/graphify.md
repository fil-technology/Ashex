# Graphify Knowledge Layer

Ashex can use a project-local Graphify graph as first-pass orientation for architecture, dependency, module-flow, onboarding, refactor, and broader build-failure questions.

Graphify context is an aid, not the source of truth. Ashex still inspects exact files and validates changes with normal tools before editing or concluding.

## Upstream Source

- Official repository: https://github.com/safishamsi/graphify
- Python package name: `graphifyy`
- Terminal entry point: `graphify`

The current upstream full initial graph build is assistant-skill-driven through `/graphify <path>`. The terminal CLI is useful after a graph exists for query, path, explain, update, watch, clustering, hooks, and related maintenance.

## Commands

Use `--workspace PATH` when you want to point at a project other than the current working directory.

```bash
ashex graphify status --workspace /path/to/project
ashex graphify build --workspace /path/to/project
ashex graphify query "How does persistence connect to the runtime?" --workspace /path/to/project
ashex graphify path "AgentRuntime" "ToolExecutor" --workspace /path/to/project
ashex graphify explain "AgentRuntime" --workspace /path/to/project
ashex graphify report --workspace /path/to/project
ashex graphify rebuild --workspace /path/to/project
ashex graphify cluster-only --workspace /path/to/project
ashex graphify clean --yes --workspace /path/to/project
```

`ashex graphify build` is intentionally guidance-oriented today. It verifies status and prints the official `/graphify <path>` instruction for first build orchestration instead of pretending there is a stable standalone upstream `graphify build` command.

After a graph exists, `ashex graphify rebuild` wraps upstream `graphify update <project>` for code-oriented maintenance. `cluster-only` wraps upstream `graphify cluster-only <project>`.

## Local Files

Graphify writes project-local output under:

- `graphify-out/graph.json`: persistent graph JSON
- `graphify-out/GRAPH_REPORT.md`: compact human-readable graph report
- `graphify-out/graph.html`: interactive graph visualization, when generated upstream
- `graphify-out/cache/`: extraction cache, which can become large

Ashex stores its own graph state at:

- `.ashex/graphify/state.json`

`ashex graphify clean --yes` removes `graphify-out` and `.ashex/graphify`. The `--yes` flag is required because this is destructive.

## Planner Behavior

Ashex requests graph context for prompts that look like:

- architecture, dependency, module, or project-structure questions
- "how does", "where is", relationship, and flow questions
- onboarding or "understand this repo" requests
- large refactor prompts
- broader build, compile, and test failure prompts

Ashex skips graph context for:

- git-only or shell-only tasks
- short edits to a known file, such as "Update README.md title"
- cases where `graphify-out/graph.json` does not exist

When graph context is available, it is injected as a bounded `<project_graph_context>` block with a query summary, related file paths, report path, and confidence. The model is instructed to treat that block as orientation only and then inspect exact files before edits.

## Troubleshooting

- If `installed` is false in `ashex graphify status --json`, install Graphify from the official repository or package source and rerun status.
- If `graphExists` is false, run the official `/graphify <path>` workflow first.
- If `reportExists` is false but `graphExists` is true, regenerate upstream report output with the official workflow or clustering path.
- If `query` fails, Ashex planner integration can fall back to `GRAPH_REPORT.md` when it exists.

See [Graphify research notes](../GRAPHIFY_RESEARCH.md) for the implementation research and upstream command mapping.
