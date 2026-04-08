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

- `allowList`: explicit command prefixes that are allowed to run
- `denyList`: explicit command prefixes that are blocked
- `requireApprovalForUnknownCommands`: when enabled, commands outside the configured allow list or outside the built-in recognized safe list require approval in guarded mode

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

TUI controls:

- `Tab`: cycle focus between launcher, settings/history panels, and input
- `Up/Down` or `j/k`: move through launcher or panel selections
- `Page Up` / `Page Down`: scroll transcripts or terminal output faster
- `Home` / `End` or `g` / `G`: jump to the oldest output or back to the live tail
- `Enter`: open the selected item or submit the current input
- `Esc` or `Left`: back out, cancel, or quit
- `t`: toggle the side terminal pane
- `x`: skip the current planned step
- `y` / `n`: approve or deny guarded actions

## Runtime boundary

The CLI is intentionally only a presentation adapter. `AgentRuntime` exposes `run(_:) -> AsyncStream<RuntimeEvent>`, which is the intended boundary for future SwiftUI integration.

## Harness boundaries

Ashex is now split a bit more like a real coding-agent harness instead of pushing everything into the model adapter:

- `PromptBuilder` assembles provider-facing static and dynamic prompt sections
- `ContextManager` prepares the active turn context, estimates token pressure, and compacts older transcript history when needed
- `WorkspaceSnapshotBuilder` captures stable repo facts up front, like top-level entries, instruction files, and lightweight git state
- `WorkingMemory` keeps a distilled per-run view of the current task, phase, inspected paths, changed paths, and suggested validation
- working memory now also keeps recent findings, completed step summaries, and unresolved items for better long-session continuity
- `ToolExecutor` owns tool resolution, approval checks, execution, persistence, and streaming tool events
- `AgentRuntime` coordinates run lifecycle, step execution, and durable run-step state while staying smaller than before

The workflow layer is now more deliberate than a generic loop:

- tasks are classified into kinds such as bug fix, feature, refactor, docs, git, shell, and analysis
- exploration and validation guidance changes by task kind
- exploration steps now carry a concrete recommended inspect/search/read sequence based on the task and workspace snapshot
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
- a structured `apply_patch` file-edit path for multi-edit diff-native mutations
- stalled-step recovery when the model keeps retrying without useful progress
- final summaries that can include changed files, why they changed, and what remains

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

## Current model behavior

`MockModelAdapter` remains the fastest local test path. `OpenAIResponsesModelAdapter`, `AnthropicMessagesModelAdapter`, and `OllamaChatModelAdapter` add real remote and local-provider paths while keeping the same runtime loop and typed `ModelAction` contract. The runtime also repairs malformed tool calls when safe, clips oversized tool output before reusing it in prompt context, and breaks repeated read-only local-model loops by returning the last good tool result.

## Current limitations

Ashex is now a serious local coding-agent foundation, but it is still not at Codex/Claude Code production maturity yet. The biggest remaining gaps are:

- deeper automatic exploration and file targeting for large coding tasks
- stronger validation execution and check selection beyond the current gating and suggestion layer
- richer patch planning and multi-file edit workflows
- even stronger longer-session memory quality and thread continuation behavior
- even more reliable large-task execution under drift and weak planning
- bounded subagents later, on top of the current single-agent harness
