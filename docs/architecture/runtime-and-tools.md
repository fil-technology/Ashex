# Runtime And Tools Guide

This page captures the deeper runtime, tool, and package-layout details that used to live in the root README.

## What It Includes

- A single-agent runtime loop with max-iteration and cancellation guards.
- A connector-ready daemon path for long-running background operation.
- Telegram Bot API polling as the first reusable messaging connector.
- Live streaming runtime events for CLI, TUI, daemon, and future UI consumers.
- SQLite persistence for threads, messages, runs, tool calls, append-only events, settings, connector mappings, and update checkpoints.
- A replaceable model boundary with `mock`, OpenAI, Anthropic, Ollama, and experimental DFlash adapters.
- A terminal TUI with chat, provider switching, workspace switching, local history browsing, side terminal, and guarded approvals.
- Bundled installable tool packs for `swiftpm`, `ios_xcode`, and `python`.

## Package Layout

- `Sources/AshexCore`: reusable runtime, tools, persistence, connector contracts, and typed event contracts.
- `Sources/AshexCLI`: command-line adapter, TUI, daemon CLI, release-facing executable entrypoint.
- `Sources/CSQLite`: small SQLite system library bridge.
- `Tests/AshexCoreTests`: focused runtime, persistence, guardrail, connector, and tool tests.
- `Tests/AshexCLITests`: CLI parser and integration-adjacent tests.

## Tool Layers

Ashex has two tool layers:

- Embedded core tools: `filesystem`, `git`, `build`, and `shell`.
- Installable tool packs exposed through the `toolpack` tool.

All tools share the same typed contract model:

- tool identity and category
- operation list
- typed arguments
- approval metadata
- structured outputs/events

This keeps approvals, sandbox integration, persistence, and model-facing tool schemas consistent between built-in and installable tools.

## Built-In Git Operations

- `status`
- `current_branch`
- `diff_unstaged`
- `diff_staged`
- `log`
- `show_commit`
- `init`
- `add`
- `add_all`
- `commit`
- `create_branch`
- `switch_branch`
- `switch_new_branch`
- `restore_worktree`
- `restore_staged`
- `reset_mixed`
- `reset_hard`
- `clean_force`
- `tag`
- `merge`
- `rebase`
- `pull`
- `push`

## Bundled Installable Packs

`swiftpm`:

- `describe_package`
- `build`
- `test`
- `run`

`ios_xcode`:

- `list`
- `build`
- `test`

`python`:

- `pytest`
- `ruff_check`
- `mypy`
- `pip_install`

Custom packs are loaded from:

- `WORKSPACE/toolpacks`
- `~/.config/ashex/toolpacks`

## Creating A Custom Tool Pack

Ashex includes an embedded `toolpack.scaffold_pack` tool that creates a starter manifest humans or agents can edit.

The manifest format is intentionally simple JSON:

- pack metadata
- tool name and description
- typed operations
- optional approval metadata
- shell command templates with placeholders like `{{path}}`

Starter packs should be easy to create by hand or through the agent because the runtime reads the same declarative format it documents in the TUI.

## Runtime Boundary

The CLI is intentionally a presentation adapter. `AgentRuntime` exposes `run(_:) -> AsyncStream<RuntimeEvent>`, which is the intended boundary for TUI, daemon, CLI, and future SwiftUI integration.

## Harness Boundaries

Ashex is split like a coding-agent harness instead of pushing everything into the model adapter:

- `PromptBuilder` assembles provider-facing static and dynamic prompt sections.
- `ContextManager` prepares active turn context, estimates token pressure, and compacts older transcript history when needed.
- `WorkspaceSnapshotBuilder` captures stable repo facts up front, like top-level entries, instruction files, project markers, source/test roots, and lightweight git state.
- `WorkingMemory` keeps a distilled per-run view of task, phase, inspected paths, changed paths, planned changes, recent findings, completed steps, carry-forward notes, and suggested validation.
- `ToolExecutor` owns tool resolution, approval checks, execution, persistence, and streaming tool events.
- `SessionInspector` provides durable run/session inspection over persisted events, steps, compactions, workspace snapshots, and working memory.
- `AgentRuntime` coordinates run lifecycle, step execution, and durable run-step state.

## Workflow Behavior

- Tasks are classified into kinds such as bug fix, feature, refactor, docs, git, shell, and analysis.
- Exploration and validation guidance changes by task kind.
- Exploration steps carry recommended inspect/search/read sequences based on the task and workspace snapshot.
- Exploration targeting persists likely files, roots, search queries, and deprioritized paths.
- Patch planning persists an explicit planned file set and patch objectives before and during mutation-heavy work.
- Runs can move through exploration, planning, mutation, and validation phases.
- Coding/edit tasks enforce inspect-before-mutate behavior.
- Changed-file tracking, validation gating, and structured patch events are surfaced through CLI/TUI state.
- Stalled-step recovery and bounded delegated subtasks exist for selected long-running phases.

## Compaction And Memory

- Older messages are summarized into a synthetic compaction summary instead of only being dropped.
- Each compaction is persisted as a `context_compactions` record.
- Each run persists workspace snapshots and rolling working memory.
- History replay surfaces working-memory state so resume context is inspectable.
- The runtime emits `contextPrepared` and `contextCompacted` events so frontends can show what happened.

## Current Model Behavior

`MockModelAdapter` remains the fastest local test path. `OpenAIResponsesModelAdapter`, `AnthropicMessagesModelAdapter`, `OllamaChatModelAdapter`, and `DFlashServerModelAdapter` keep the same runtime loop and typed `ModelAction` contract where supported. The runtime repairs malformed tool calls when safe, clips oversized tool output before reusing it in prompt context, and breaks repeated read-only local-model loops by returning the last useful tool result.

## Current Limitations

Ashex is a serious local coding-agent foundation, but it is still not at Codex/Claude Code maturity yet. The biggest remaining gaps are:

- stronger validation execution and check selection
- richer patch planning and multi-file edit workflows
- stronger longer-session memory quality and thread continuation behavior
- more reliable large-task execution under drift and weak planning
- richer delegated-agent orchestration beyond the current bounded subtask flow

The current next-stage roadmap lives in [Production refinement roadmap](../roadmap/production-refinement-roadmap.md). The concrete remaining production-grade checklist lives in [Production readiness checklist](../release/production-readiness-checklist.md).
