# ASHEX Agent Architecture Gap Report

Generated during the Hermes/OpenKB-style self-improving agent implementation pass.

Status: the first implementation wave is now in place. The codebase has durable agent home/context/memory/skill/KB stores, JSONL transcripts, SQLite session search, summaries, background task and process primitives, heartbeat stale-task recovery, learning logs, MCP/RPC/model-routing foundations, and CLI management commands for the implemented surfaces.

## Existing Modules

- Runtime loop: `Sources/AshexCore/AgentRuntime.swift` owns threads, runs, step planning, tool calls, delegation, working memory, validation gates, and final summaries.
- Tool contracts and execution: `Sources/AshexCore/Tools.swift`, `ToolExecutor.swift`, `FileSystemTool.swift`, `ShellTool.swift`, `GitTool.swift`, `BuildTool.swift`, browser tools, audio tools, and installable tool packs provide the current command surface.
- Persistence: `Sources/AshexCore/Persistence.swift` and `SQLitePersistence.swift` persist threads, messages, runs, steps, tool calls, events, workspace snapshots, context compactions, working memory, and settings.
- Context and run memory: `Prompting.swift`, `ContextPlanning.swift`, `WorkspaceSnapshot.swift`, `SessionInspector.swift`, and working-memory records provide bounded run context, compaction, and replay summaries.
- Esh integration: `EshBridgeModelAdapter.swift` bridges ASHEX to `esh` capabilities, direct infer requests, cache artifacts, and legacy cache load flows.
- Configuration and safety: `UserConfig.swift`, `Approval.swift`, `ShellExecutionPolicy.swift`, `WorkspaceGuard.swift`, and CLI/TUI provider routing implement local configuration, approvals, protected paths, and provider recovery hints.
- Background and connectors: `DaemonSupervisor.swift`, `RunDispatcher.swift`, `CronJobs.swift`, and Telegram connector code provide the current daemon, cron, and messaging extension points.
- Subagents: `DelegationStrategy.swift` and `AgentRuntime` delegated loops support bounded read-only workstreams for selected steps.
- Browser/web: `Sources/AshexCore/Browser/*` and browser tools already expose local browser fetch, extract, eval, and screenshot capabilities.

## Phase Mapping

- Phase 0: Gap reporting exists here and must stay current before further behavior changes.
- Phases 1-3: Home layout, SOUL/context files, curated memory files, context loading priority, memory edit/search tools, and prompt-injection warnings are implemented for the first slice.
- Phase 4: SQLite thread/message/run storage exists. FTS-backed search with a LIKE fallback, JSONL session transcripts, and deterministic summaries are implemented in core with CLI access.
- Phase 5: A typed tool contract/registry exists. Named bundled tool-pack persistence exists; richer per-platform availability remains future depth.
- Phase 6: Foreground shell execution, streaming, approvals, sandbox policy, and risk assessment exist. Persistent background process list/poll/log/wait/kill/write metadata is implemented.
- Phase 7: Planner/executor/verifier phases exist in the runtime; durable task queue primitives now exist, while automatic build/test detection can still deepen.
- Phases 8-10: Portable `SKILL.md` stores, quarantine/audit, skill routing, and generated skill drafts are implemented as core/CLI surfaces.
- Phase 11: Project learning logs are implemented.
- Phases 12-14: Cron exists and daemon dispatch exists; heartbeat stale-task detection and durable queue claim/done/fail/retry are implemented.
- Phase 15: MCP now has config/namespace/discovery foundations, CLI registry management, live stdio/HTTP list discovery for tools/resources/prompts, and an ASHEX stdio MCP server; external `tools/call` bridging remains a later transport step.
- Phase 16: Delegation exists in runtime form; isolated workspace controls remain future depth.
- Phase 17: Programmatic in-process tool RPC is implemented with policy evaluation.
- Phase 18: Explicit model routing buckets are implemented as deterministic core primitives with CLI inspection.
- Phase 19: Browser hooks are mostly present and need registry/toolset integration.
- Phase 20: Command safety exists; prompt-injection scanning, broader redaction, and audit logs for new knowledge surfaces need to be added.
- Phase 21: TUI has runtime/provider/history surfaces, but the requested Agent Operations management screens are not all present.
- Phase 22: Dedicated `ashex doctor` is implemented.
- Phase 23: Architecture docs exist in part; the requested focused docs need to be added or expanded.
- Phase 24: Existing tests cover runtime, shell policy, browser, persistence, tool packs, connectors, agent home layout, context files, memory files, skills, MCP foundations, KB, RPC policy, sessions, queues, heartbeats, routing, learning logs, and process metadata.
- OpenKB addendum: No compiled markdown wiki layer currently exists.

## Gaps Against The Prompt

- Durable `~/.ashex/SOUL.md`, project `AGENTS.md`, `.ashex.md`, `ASHEX.md`, and compatible context-file loading are partial; workspace snapshots record instruction files, but prompt-injection warnings and lazy subdirectory context loading are not complete.
- Persistent curated memory now has explicit agent/user/project/lesson memory files with agent-editable operations and audit trails.
- Portable `SKILL.md` procedural memory now has install/list/show/audit/quarantine/create/export/remove operations plus routing foundations.
- MCP support now has config-driven stdio/HTTP descriptors, persisted registry management, namespace/filter primitives, live external list discovery, and ASHEX stdio server mode; external MCP tool invocation remains future work.
- Session storage now includes JSONL transcripts, FTS5/LIKE search, and summaries.
- Programmatic RPC for scripts now has an in-process JSON-RPC-style request/response and policy-evaluated tool calls.
- Terminal backends are local-first; docker/ssh/cloud backend abstractions remain future work.
- Self-improvement has planning and working-memory primitives, but no reviewable skill-amendment loop.
- OpenKB-style compiled knowledge storage, ingestion, query, lint, and wiki report directories are implemented for markdown/wiki workflows.

## Risky Areas

- `esh` cache artifact construction can use a larger memory working set than direct `esh infer`; ASHEX should retry direct infer for the same request before falling back to a different adapter when cache build/load hits memory pressure.
- Adding memory, skills, MCP, and KB surfaces must preserve the existing tool contract, approval, workspace guard, and audit behavior.
- Context growth from SOUL, memory, skill instructions, and KB summaries must remain budgeted to avoid worsening local runtime pressure.
- Skill and context files can contain hostile instructions. Loading code must scan and warn before injection rather than blindly trusting local text.
- New file-backed state must not store secrets and must not silently overwrite user-authored KB/wiki pages.
- TUI changes touch a very large file; management screens should be added incrementally to avoid regressions in existing chat/provider flows.

## Proposed Implementation Order

1. Keep expanding CLI/TUI ergonomics around the implemented core primitives.
2. Add external MCP `tools/call` invocation with approval/audit integration.
3. Connect skill-routing and model-routing outputs directly into runtime planning/model selection.
4. Add isolated subagent workspace controls and fuller Agent Operations TUI screens.

## Storage And Config Migrations

- Existing SQLite stores remain compatible. A later FTS5 migration should add virtual indexes without changing current tables.
- This pass should introduce file-backed state under the selected ASHEX storage root:
  - `SOUL.md`
  - `config.toml`
  - `state.sqlite` compatibility placeholder while existing `ashex.sqlite` remains supported
  - `sessions/`
  - `memory/MEMORY.md`, `memory/USER.md`, `memory/PROJECTS.md`, `memory/LESSONS.md`
  - `skills/installed`, `skills/quarantined`, `skills/generated`
  - `tasks/`, `cron/jobs.toml`, `cron/history.jsonl`
  - `logs/ashex.log`, `logs/tool_calls.jsonl`
  - `mcp/servers.json`
  - `approvals/allowlist.toml`, `approvals/audit.jsonl`
- Project-local additions:
  - `.ashex/memory/project.md`
  - `.ashex/skills/`, `.ashex/tasks/`, `.ashex/logs/`
  - `.learnings/LEARNINGS.md`, `ERRORS.md`, `FEATURE_REQUESTS.md`, `CORRECTIONS.md`
  - `.ashex/kb/` markdown wiki layout from the OpenKB addendum
- Existing `ashex.config.json`, `.ashex/ashex.sqlite`, `.ashex/secrets.json`, and toolpacks remain compatible.

## Tests To Add

- `EshBridgeModelAdapterTests`: cache-build memory pressure falls back to direct `esh infer` and preserves model, messages, generation settings, and attachments.
- `AgentHomeTests`: initializes global/project layout idempotently without overwriting user-authored files.
- `AgentMemoryStoreTests`: add, replace, remove, search, secret redaction, and audit logging for memory files.
- `AgentSkillStoreTests`: install portable `SKILL.md` folders into quarantine, parse metadata progressively, audit prompt-injection patterns, enable/list/show/export.
- `AgentMCPRegistryTests`: upsert/list/remove stdio and HTTP server configs with allow/deny tool filters.
- `AgentKnowledgeBaseTests`: initialize OpenKB wiki, ingest markdown/text files, query compiled wiki text, lint missing sources/orphans, and preserve provenance.
- `AgentKnowledgeToolsTests`: runtime tools expose the memory, skill, MCP, and KB stores through normal `Tool` contracts.
- CLI tests for `context`, `soul`, `memory`, `skills`, `mcp`, `kb`, `sessions`, `tasks`, `processes`, `learnings`, `routes`, `rpc`, and `doctor` command parsing/outputs.
