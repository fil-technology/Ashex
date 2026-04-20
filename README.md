# Ashex

Ashex is a local-first coding agent runtime for macOS, built as a Swift package with a reusable core runtime, a terminal TUI, and a connector-ready daemon.

It is designed for people who want a transparent, hackable agent shell with typed tools, persistent runs, guarded execution, and room to evolve toward stronger coding-assistant behavior without turning into a black box.

## What it includes

- A real single-agent loop with max-iteration and cancellation guards
- A connector-ready daemon path for long-running background operation
- Telegram Bot API polling as the first reusable messaging connector
- Telegram typing indicators and HTML-formatted replies for connector output
- Telegram-triggered tool execution when the connector is set to `trusted_full_access`
- Multiple local coding tools behind a typed runtime:
  - `filesystem`
  - `git`
  - inspect and mutate repository state through typed git operations
  - `build`
  - `shell`
  - `toolpack` scaffold support for installable tool manifests
- Live streaming runtime events for CLI or future UI consumers
- SQLite persistence for threads, messages, runs, tool calls, and append-only events
- Generic SQLite-backed persisted settings for session defaults and future runtime preferences
- Persistent connector conversation mappings and Telegram update checkpoints stored in the existing SQLite settings table
- Restart normalization that marks previously running work as `interrupted`
- A replaceable model boundary with `mock`, OpenAI, Anthropic, local Ollama-backed, and experimental DFlash-backed adapters
- A terminal TUI with provider switching, workspace switching, local history browsing, side terminal, and guarded approvals
- Bundled installable tool packs for `swiftpm`, `ios_xcode`, and `python`

## Package layout

- `Sources/AshexCore`: reusable runtime, tools, persistence, and typed event contracts
- `Sources/AshexCLI`: command-line adapter that renders streamed runtime events
- `Sources/CSQLite`: small SQLite system library bridge
- `Tests/AshexCoreTests`: focused runtime and guardrail tests

## Documentation

Repository documentation is now grouped under `docs/` so the project root stays focused on code and release entrypoints.

- `docs/README.md`: top-level documentation map
- `docs/roadmap/implementation-phases.md`: original build-up phases from the MVP foundation
- `docs/roadmap/production-milestones.md`: completed production-shaping milestones
- `docs/roadmap/production-refinement-roadmap.md`: current phase-by-phase refinement plan
- `docs/release/production-readiness-checklist.md`: production and shipping checklist
- `docs/connectors/daemon-telegram-mvp.md`: daemon and Telegram connector architecture notes
- `docs/providers/dflash-provider-plan.md`: DFlash integration plan and follow-up work
- `docs/adoption/ash-optimization-adoption-plan.md`: Ash optimization adoption seam notes
- `docs/adoption/ash-to-ashex-adoption-plan.md`: broader Ash-to-Ashex transfer plan
- `docs/research/omlx-evaluation.md`: research notes for the oMLX evaluation

## Quick start

```bash
swift build
swift run ashex
swift run ashex "list files"
swift run ashex "read README.md"
swift run ashex 'write notes/todo.txt :: buy milk'
swift run ashex "swift build"
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

Release packaging and Homebrew prep:

```bash
./scripts/package_source_release.sh v0.2.0
./scripts/package_release.sh v0.2.0
./scripts/render_homebrew_formula.sh \
  --version v0.2.0 \
  --source-url https://github.com/fil-technology/Ashex/releases/download/v0.2.0/ashex-v0.2.0-source.tar.gz \
  --sha256 <release-source-tarball-sha256>
```

Once the release asset and formula are published, the install path is:

```bash
brew install fil-technology/tap/ashex
```

TUI highlights:

- Switch between `mock`, `ollama`, `dflash`, `openai`, and `anthropic` without restarting
- Use `Assistant Setup` in the launcher to configure provider, Telegram, and daemon controls
- Treat `Assistant Setup` like a short onboarding flow: provider first, then Telegram token, then daemon start
- Edit the active model name from the TUI
- Save provider API keys from the TUI settings screen
- Save the Telegram bot token from the TUI into macOS Keychain
- Enable Telegram, set safety mode, edit allowed chat IDs, test connectivity, and start/stop the daemon from the TUI
- Choose DFlash in Provider Settings when you want Apple-Silicon-local direct chat through `dflash-serve`
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

Experimental DFlash-backed mode:

```bash
dflash-serve --model Qwen/Qwen3.5-4B --port 8000
export DFLASH_BASE_URL=http://127.0.0.1:8000
swift run ashex --provider dflash --model Qwen/Qwen3.5-4B "say hello"
```

DFlash is direct-chat only for now, so tool-calling stays on the other providers.

CLI options:

- `--workspace PATH`: workspace root enforced by `WorkspaceGuard`
- `--storage PATH`: persistence directory, default `WORKSPACE/.ashex`
- `--max-iterations N`: loop limit, default `8`
- `--provider mock|openai|anthropic|ollama|dflash`: model adapter selection
- `--model MODEL`: model name for provider-backed mode
- `--approval-mode trusted|guarded`: execution policy, default `trusted`

Daemon and Telegram commands:

- `daemon run`: start Ashex in the foreground as a long-running process
- `daemon start`: launch the daemon in the background and write logs under `STORAGE/daemon/daemon.log`
- `daemon stop`: send `SIGTERM` to the tracked daemon process
- `daemon status`: show PID and log path when the daemon is running
- `telegram test`: verify the configured Telegram bot token with `getMe`
- `cron list`: list persisted cron jobs
- `cron add --id ID --expr "MIN HOUR DAY MONTH WEEKDAY" --tz "Area/City" --prompt "..."`: add a timezone-aware recurring cron job
- `cron remove --id ID`: remove a persisted cron job

Example:

```bash
export ASHEX_TELEGRAM_BOT_TOKEN=123456:bot-token
swift run ashex telegram test
swift run ashex daemon run --provider openai --model gpt-5.4-mini
swift run ashex cron add --id morning-brief --expr "0 7 * * 1-5" --tz "Asia/Jerusalem" --prompt "Summarize overnight repo updates and list urgent follow-ups."
```

TUI onboarding path:

1. Launch `swift run ashex`
2. Open `Assistant Setup` from the launcher
3. Choose the provider and model you want for daemon runs
4. Save the provider API key if needed
5. Enable Telegram, choose an access mode, and save the Telegram bot token
6. If access gating is enabled, save allowed private chat IDs and optional user IDs
7. Use `Telegram Test` to verify the bot token
8. Use `Daemon` to start the background process

After that, the bot should keep running until you stop the daemon from the same settings screen or by CLI.
The daemon can also run with cron jobs only, even if Telegram is disabled, as long as at least one enabled cron job exists.

Provider environment variables:

- `OPENAI_API_KEY`: required for `--provider openai`
- `ANTHROPIC_API_KEY`: required for `--provider anthropic`
- `OPENAI_MODEL`: optional default model for `openai`
- `OLLAMA_MODEL`: optional default model for `ollama`
- `OLLAMA_BASE_URL`: optional Ollama chat endpoint, default `http://localhost:11434/api/chat`
- `OLLAMA_REQUEST_TIMEOUT_SECONDS`: optional Ollama request timeout override for slower agent-mode calls
- `DFLASH_MODEL`: optional default model for `dflash`
- `DFLASH_BASE_URL`: optional DFlash server endpoint, default `http://127.0.0.1:8000`
- `ASHEX_ALLOW_LARGE_MODELS=1`: optional override if you intentionally want to bypass local-model memory guardrails
- `ASHEX_TELEGRAM_BOT_TOKEN`: optional Telegram bot token override for daemon mode

Shell policy config in `ashex.config.json`:

- `sandbox.mode`: `read_only`, `workspace_write`, or `danger_full_access`
- `sandbox.protectedPaths`: workspace-relative paths that remain protected in `workspace_write` mode
- `network.mode`: `allow`, `prompt`, or `deny` for network-affecting shell commands
- `network.rules`: explicit network command prefix actions with `allow`, `prompt`, or `deny`
- `allowList`: explicit command prefixes that are allowed to run
- `denyList`: explicit command prefixes that are blocked
- `rules`: explicit per-prefix actions with `allow`, `prompt`, or `deny`
- `requireApprovalForUnknownCommands`: when enabled, commands outside the configured allow list or outside the built-in recognized safe list require approval in guarded mode

Daemon and Telegram config in `ashex.config.json`:

- `daemon.enabled`: reserved toggle for daemon-oriented deployments
- `logging.level`: `debug`, `info`, `warning`, or `error`
- `telegram.enabled`: enables the Telegram connector for daemon runs
- `telegram.botToken`: optional bot token if you do not want to use `ASHEX_TELEGRAM_BOT_TOKEN`
- `telegram.pollingTimeoutSeconds`: long-poll timeout for `getUpdates`
- `telegram.accessMode`: `open` or `allowlist_only`
- `telegram.allowedChatIDs`: optional allowlist of Telegram private chat IDs
- `telegram.allowedUserIDs`: optional allowlist of Telegram user IDs
- `telegram.responseMode`: currently `final_message`
- `telegram.executionPolicy`: `assistant_only`, `approval_required`, or `trusted_full_access`
- `ollama.requestTimeoutSeconds`: request timeout for Ollama chat and agent-mode requests, default `180`
- `dflash.enabled`: optional toggle for the experimental DFlash provider
- `dflash.baseURL`: local `dflash-serve` endpoint, default `http://127.0.0.1:8000`
- `dflash.model`: default model for the DFlash provider
- `dflash.draftModel`: optional draft model override for `dflash-serve`
- `dflash.requestTimeoutSeconds`: request timeout for the DFlash server client

Recommended safe starting config:

```json
{
  "telegram": {
    "enabled": true,
    "accessMode": "allowlist_only",
    "executionPolicy": "assistant_only",
    "pollingTimeoutSeconds": 20,
    "allowedChatIDs": ["123456789"],
    "allowedUserIDs": ["123456789"]
  },
  "logging": {
    "level": "info"
  }
}
```

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

For Telegram daemon mode:

- `assistant_only` denies all approval-gated tool actions, which keeps Telegram as a read-only assistant entrypoint for normal chat
- `approval_required` now opens a remote approval inbox inside the Telegram chat and waits for `/approve` or `/deny`
- `trusted_full_access` allows Telegram to use the existing runtime tool path, while the sandbox and shell/network policies still apply
- `accessMode: open` keeps the bot reachable from any private Telegram chat
- `accessMode: allowlist_only` rejects unapproved chats and sends an onboarding reply that includes the sender's chat ID and user ID
- direct-chat prompts such as "How are you?" are routed normally and show a typing indicator while the model runs
- Telegram now prefers direct-chat routing for general requests like summaries, explanations, code snippets, weather/news lookups, and similar conversational asks
- project or workspace prompts, or explicit command-style prompts like `shell: ...`, go through the normal runtime intent classifier and can execute tools in trusted mode
- `/status`, `/pending`, `/approve`, `/deny [reason]`, and `/stop` are available in Telegram while a run is active
- the connector never silently escalates to trusted execution

When `allowlist_only` is enabled, unauthorized users receive a setup message with:

- their Telegram chat ID
- their Telegram user ID
- the exact `Assistant Setup` fields to update in Ashex
- a reminder to restart the daemon after changing the allowlist

Telegram replies use Telegram HTML parse mode, so bold text and code blocks render, but raw Markdown is not passed through unchanged.

For owner-controlled bots, `trusted_full_access` is the mode that enables Telegram-triggered tool use. For shared or public bots, stay on `assistant_only`.

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
- `/toolpacks`: show bundled and custom installable tool packs
- `/install-pack swiftpm`: enable a bundled installable tool pack
- `/uninstall-pack python`: disable a bundled installable tool pack
- supported aliases: `:workspace /path`, `workspace /path`, `cd /path`, `/cd /path`

## Tool Contracts And Installable Tool Packs

Ashex now has two tool layers:

- embedded core tools:
  - `filesystem`
  - `git`
  - `build`
  - `shell`
- `toolpack`

The built-in `git` tool supports both read-only and mutating operations including:

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

For a disposable real-model end-to-end test, you can also use:

```bash
export OPENAI_API_KEY=your_key_here
./scripts/smoke_real_model_project_flow.sh /tmp/ashex-smoke DemoApp openai gpt-5.4
```

## Daemon Architecture

The daemon path is additive and keeps the core runtime intact:

- `AgentRuntime` can now run against an existing persisted thread, which allows external connectors to resume conversations instead of always starting from scratch
- `ConnectorRegistry` and `Connector` provide a connector-agnostic lifecycle and outbound messaging boundary
- `ConversationRouter` and `ConnectorConversationMappingStore` map external conversations such as Telegram chat IDs to internal Ash thread IDs using the existing SQLite settings store
- `RunDispatcher` submits inbound connector prompts through the normal runtime event stream and captures the final answer
- `DaemonSupervisor` handles commands such as `/start`, `/help`, `/reset`, `/status`, `/pending`, `/approve`, `/deny`, and `/stop`, then routes normal text into the runtime
- `TelegramConnector` uses Bot API polling, persists processed `update_id` values, ignores unsupported updates cleanly, and sends final text responses back in chunks

Current connector limitations:

- Telegram private chats only
- replies are currently emitted as final messages rather than true streamed chunks
- webhook deployment is not wired yet
- remote approvals currently live inside the same Telegram conversation and are limited to one pending approval per chat

Implementation notes and next-step recommendations live in [`docs/connectors/daemon-telegram-mvp.md`](docs/connectors/daemon-telegram-mvp.md).
- installable tool packs:
  - bundled now: `swiftpm`, `ios_xcode`, `python`
  - custom packs loaded from:
    - `WORKSPACE/toolpacks`
    - `~/.config/ashex/toolpacks`

All tools use the same typed contract model:

- tool identity and category
- operation list
- typed arguments
- approval metadata
- structured outputs/events

This keeps approvals, sandbox integration, persistence, and model-facing tool schemas consistent between built-in and installable tools.

### Bundled Installable Packs

- `swiftpm`
  - `describe_package`
  - `build`
  - `test`
  - `run`
- `ios_xcode`
  - `list`
  - `build`
  - `test`
- `python`
  - `pytest`
  - `ruff_check`
  - `mypy`
  - `pip_install`

### Creating A Custom Tool Pack

Ashex includes an embedded `toolpack.scaffold_pack` tool that creates a starter manifest which humans or other agents can edit.

The manifest format is intentionally simple JSON:

- pack metadata
- tool name and description
- typed operations
- optional approval metadata
- shell command templates with placeholders like `{{path}}`

Starter packs should be easy to create by hand or through the agent because the runtime reads the same declarative format it documents in the TUI.

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
- exploration targeting now also persists deprioritized paths so the harness can keep low-signal areas out of the active search cone until new evidence appears
- exploration targeting now also uses persisted project markers and source/test roots instead of only broad top-level folder guesses
- exploration updates are now surfaced as first-class CLI/TUI state instead of only raw transcript lines
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
- typed build actions for SwiftPM and Xcode projects, including `swift_build`, `swift_test`, `xcodebuild_list`, `xcodebuild_build`, and `xcodebuild_test`
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

- stronger validation execution and check selection beyond the current gating and suggestion layer
- richer patch planning and multi-file edit workflows
- even stronger longer-session memory quality and thread continuation behavior
- even more reliable large-task execution under drift and weak planning
- richer delegated-agent orchestration beyond the current bounded subtask flow

The current next-stage roadmap for those areas lives in [`docs/roadmap/production-refinement-roadmap.md`](docs/roadmap/production-refinement-roadmap.md).
The concrete remaining production-grade checklist lives in [`docs/release/production-readiness-checklist.md`](docs/release/production-readiness-checklist.md).
