# Ashex MVP

Ashex is a minimal local agent runtime foundation for macOS, built as a small Swift package with a reusable core runtime and a thin CLI adapter.

## What this MVP includes

- A real single-agent loop with max-iteration and cancellation guards
- Multiple local coding tools behind a typed runtime:
  - `filesystem`
  - `git`
  - `shell`
- Live streaming runtime events for CLI or future UI consumers
- SQLite persistence for threads, messages, runs, tool calls, and append-only events
- Generic SQLite-backed persisted settings for session defaults and future runtime preferences
- Restart normalization that marks previously running work as `interrupted`
- A replaceable model boundary with `mock`, OpenAI, Anthropic, and local Ollama-backed adapters
- A terminal TUI with provider switching, workspace switching, local history browsing, side terminal, and guarded approvals

## Package layout

- `Sources/AshexCore`: reusable runtime, tools, persistence, and typed event contracts
- `Sources/AshexCLI`: command-line adapter that renders streamed runtime events
- `Sources/CSQLite`: small SQLite system library bridge
- `Tests/AshexCoreTests`: focused runtime and guardrail tests

## Quick start

```bash
swift build
swift run ashex
swift run ashex "list files"
swift run ashex "read README.md"
swift run ashex 'write notes/todo.txt :: buy milk'
swift run ashex 'shell: ls -la'
```

Running `swift run ashex` with no prompt starts the interactive terminal TUI.

Install once, then launch like a normal command:

```bash
./scripts/install.sh
~/.local/bin/ashex
```

Single-command install and launch from the repo root:

```bash
./scripts/install.sh && ~/.local/bin/ashex
```

If `~/.local/bin` is already in your `PATH`, the one-liner becomes:

```bash
./scripts/install.sh && ashex
```

You can also install somewhere else:

```bash
./scripts/install.sh /usr/local/bin
```

TUI highlights:

- Switch between `mock`, `ollama`, `openai`, and `anthropic` without restarting
- Edit the active model name from the TUI
- Save provider API keys from the TUI settings screen
- Store provider API keys in macOS Keychain instead of SQLite settings
- Persist provider/model defaults across launches
- Switch the active workspace live from the TUI or with `:workspace /path`
- Switch the active workspace live from the input bar with `/workspace /path`
- Browse and switch recent workspaces from a dedicated Workspaces screen
- Browse persisted thread/run history and load prior transcripts back into the viewer
- Open a side terminal pane for quick workspace commands
- Review guarded approval requests with shell/file previews before allowing execution
- Apply local-model memory guardrails based on the Mac's available RAM and installed model sizes

OpenAI-backed mode:

```bash
export OPENAI_API_KEY=your_key_here
swift run ashex --provider openai --model gpt-5.4-mini "list the files in this workspace"
```

Local Ollama-backed mode:

```bash
ollama serve
ollama pull llama3.2
swift run ashex --provider ollama --model llama3.2 "list the files in this workspace"
```

CLI options:

- `--workspace PATH`: workspace root enforced by `WorkspaceGuard`
- `--storage PATH`: persistence directory, default `WORKSPACE/.ashex`
- `--max-iterations N`: loop limit, default `8`
- `--provider mock|openai|anthropic|ollama`: model adapter selection
- `--model MODEL`: model name for provider-backed mode
- `--approval-mode trusted|guarded`: execution policy, default `trusted`

Provider environment variables:

- `OPENAI_API_KEY`: required for `--provider openai`
- `ANTHROPIC_API_KEY`: required for `--provider anthropic`
- `OPENAI_MODEL`: optional default model for `openai`
- `OLLAMA_MODEL`: optional default model for `ollama`
- `OLLAMA_BASE_URL`: optional Ollama chat endpoint, default `http://localhost:11434/api/chat`
- `ASHEX_ALLOW_LARGE_MODELS=1`: optional override if you intentionally want to bypass local-model memory guardrails

Shell policy config in `ashex.config.json`:

- `sandbox.mode`: `read_only`, `workspace_write`, or `danger_full_access`
- `sandbox.protectedPaths`: workspace-relative paths that remain protected in `workspace_write` mode
- `network.mode`: `allow`, `prompt`, or `deny` for network-affecting shell commands
- `network.rules`: explicit network command prefix actions with `allow`, `prompt`, or `deny`
- `allowList`: explicit command prefixes that are allowed to run
- `denyList`: explicit command prefixes that are blocked
- `rules`: explicit per-prefix actions with `allow`, `prompt`, or `deny`
- `requireApprovalForUnknownCommands`: when enabled, commands outside the configured allow list or outside the built-in recognized safe list require approval in guarded mode

Config precedence:

- project config: `WORKSPACE/ashex.config.json`
- optional global config: `~/.config/ashex/ashex.config.json`
- project config overrides global config key-by-key

Provider secrets:

- OpenAI and Anthropic API keys entered in the TUI are stored in macOS Keychain
- environment variables still take precedence over locally saved secrets
- older SQLite-stored provider secrets are migrated forward automatically when read

Guarded mode examples:

```bash
swift run ashex --approval-mode guarded 'shell: pwd'
swift run ashex --approval-mode guarded
```

In guarded mode:

- shell commands require approval
- filesystem writes and mutating filesystem operations require approval
- read-only filesystem operations continue without prompting
- shell commands outside configured allow/safe rules can also be escalated into the same approval flow
- read-only sandbox mode blocks filesystem mutations and mutating shell commands before approval logic even runs
- workspace-write sandbox mode protects sensitive paths like `.git`, `.ashex`, `.codex`, and `ashex.config.json` by default
- network policy is enforced as a first-class rule for shell execution, including the side terminal pane

TUI controls:

- `Tab`: cycle focus between launcher, settings/history panels, and input
- `Workspaces`: inspect recent project roots, latest run state, and switch sessions without typing paths
- `Up/Down` or `j/k`: move through launcher or panel selections
- `Page Up` / `Page Down`: scroll transcripts or terminal output faster
- `Home` / `End` or `g` / `G`: jump to the oldest output or back to the live tail
- `Enter`: open the selected item or submit the current input
- `Esc` or `Left`: back out, cancel, or quit
- `t`: toggle the side terminal pane
- `x`: skip the current planned step
- `y` / `n`: approve or deny guarded actions

Live workspace commands in the running TUI:

- `/workspace /full/path/to/project`: switch the current session to a different workspace
- `/workspaces`: open the recent-workspaces picker
- `/pwd`: show the current active workspace
- `/sandbox`: show the current effective sandbox and command-policy state
- supported aliases: `:workspace /path`, `workspace /path`, `cd /path`, `/cd /path`

## Runtime boundary

The CLI is intentionally only a presentation adapter. `AgentRuntime` exposes `run(_:) -> AsyncStream<RuntimeEvent>`, which is the intended boundary for future SwiftUI integration.

## Harness boundaries

Ashex is now split a bit more like a real coding-agent harness instead of pushing everything into the model adapter:

- `PromptBuilder` assembles provider-facing static and dynamic prompt sections
- `ContextManager` prepares the active turn context, estimates token pressure, and compacts older transcript history when needed
- `WorkspaceSnapshotBuilder` captures stable repo facts up front, like top-level entries, instruction files, and lightweight git state
- workspace snapshots now also persist project markers plus likely source/test roots so exploration starts from a better repo profile
- `WorkingMemory` keeps a distilled per-run view of the current task, phase, inspected paths, changed paths, and suggested validation
- working memory now also keeps recent findings, completed step summaries, and unresolved items for better long-session continuity
- working memory now also keeps exploration targets and still-pending exploration targets for better file targeting during larger coding tasks
- working memory now also keeps a planned change set, patch objectives, and carry-forward notes so longer coding sessions preserve intended file scope and open follow-ups
- `ToolExecutor` owns tool resolution, approval checks, execution, persistence, and streaming tool events
- `SessionInspector` provides a cleaner durable run/session inspection boundary over persisted events, steps, compactions, workspace snapshots, and working memory
- `AgentRuntime` coordinates run lifecycle, step execution, and durable run-step state while staying smaller than before

The workflow layer is now more deliberate than a generic loop:

- tasks are classified into kinds such as bug fix, feature, refactor, docs, git, shell, and analysis
- exploration and validation guidance changes by task kind
- exploration steps now carry a concrete recommended inspect/search/read sequence based on the task and workspace snapshot
- exploration targeting now persists likely files, roots, and search queries so history and resumed runs can see what the harness thought was worth inspecting
- exploration targeting now also uses persisted project markers and source/test roots instead of only broad top-level folder guesses
- patch planning now persists an explicit planned file set and patch objectives before and during mutation-heavy work
- the runtime carries those hints into the phased execution flow so coding tasks explore and validate more intentionally

Current runtime capabilities also include:

- phased runs:
  - exploration
  - planning
  - mutation
  - validation
- inspect-before-mutate enforcement for coding and edit tasks
- changed-file tracking during the run
- validation gating that asks the model for concrete verification before concluding an edited run
- validation execution can now proactively run checks like `git diff`, read-back verification, and workspace-aware build/test commands for SwiftPM, JavaScript package managers, Rust, and Go projects when the model tries to conclude too early
- a structured `apply_patch` file-edit path for multi-edit diff-native mutations
- explicit patch-plan events that surface the current intended multi-file change set and its goals in the CLI/TUI
- stalled-step recovery when the model keeps retrying without useful progress
- bounded delegated subtasks for selected non-mutation phases, with a smaller iteration budget and visible subagent events
- bounded delegated subtasks can now fan out into safer parallel read-only exploration and validation lanes when the task has enough meaningful scoped targets
- delegated subtasks now use an explicit assignment and handoff model with role, goal, and remaining-item reporting
- delegated handoffs now feed back into working memory as carry-forward notes and recommended follow-up paths
- final summaries that can include changed files, why they changed, and what remains
- explicit sandbox-policy and approval-policy separation so execution constraints can evolve without rewriting the loop

The first compaction strategy is intentionally simple but real:

- older messages are not only dropped; they are summarized into a synthetic compaction summary
- each compaction is persisted in SQLite as a `context_compactions` record
- each run also persists a `workspace_snapshots` record and a rolling `working_memory` record
- history replay surfaces the persisted working-memory state so resume context is inspectable instead of hidden in raw transcript only
- the runtime emits both `contextPrepared` and `contextCompacted` events so the CLI/TUI can surface what happened

This keeps the current single-agent runtime small while creating clean seams for future:

- smarter compaction
- prompt caching
- richer task/session state
- delegated subagents later on top of the same harness
- more decoupled session / harness / tool-execution evolution as the runtime grows

## Current model behavior

`MockModelAdapter` remains the fastest local test path. `OpenAIResponsesModelAdapter`, `AnthropicMessagesModelAdapter`, and `OllamaChatModelAdapter` add real remote and local-provider paths while keeping the same runtime loop and typed `ModelAction` contract. The runtime also repairs malformed tool calls when safe, clips oversized tool output before reusing it in prompt context, and breaks repeated read-only local-model loops by returning the last good tool result.

## Current limitations

Ashex is now a serious local coding-agent foundation, but it is still not at Codex/Claude Code production maturity yet. The biggest remaining gaps are:

- deeper automatic exploration and file targeting for large coding tasks
- stronger validation execution and check selection beyond the current gating and suggestion layer
- richer patch planning and multi-file edit workflows
- even stronger longer-session memory quality and thread continuation behavior
- even more reliable large-task execution under drift and weak planning
- richer delegated-agent orchestration beyond the current bounded subtask flow

The current next-stage roadmap for those areas lives in `PRODUCTION_REFINEMENT_ROADMAP.md`.
The concrete remaining production-grade checklist lives in `PRODUCTION_READINESS_CHECKLIST.md`.
