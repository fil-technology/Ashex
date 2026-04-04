# Ashex MVP

Ashex is a minimal local agent runtime foundation for macOS, built as a small Swift package with a reusable core runtime and a thin CLI adapter.

## What this MVP includes

- A real single-agent loop with max-iteration and cancellation guards
- Exactly two tools: `filesystem` and `shell`
- Live streaming runtime events for CLI or future UI consumers
- SQLite persistence for threads, messages, runs, tool calls, and append-only events
- Generic SQLite-backed persisted settings for session defaults and future runtime preferences
- Restart normalization that marks previously running work as `interrupted`
- A replaceable model boundary with mock, OpenAI, and local Ollama-backed adapters
- A terminal TUI with provider switching, local history browsing, and guarded approvals

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

TUI highlights:

- Switch between `mock`, `ollama`, and `openai` without restarting
- Edit the active model name from the TUI
- Persist provider/model defaults across launches
- Browse persisted thread/run history and load prior transcripts back into the viewer
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
- `--provider mock|openai|ollama`: model adapter selection, default `mock`
- `--model MODEL`: model name for provider-backed mode. Defaults to `gpt-5.4-mini` for OpenAI and `llama3.2` for Ollama.
- `--approval-mode trusted|guarded`: execution policy, default `trusted`

Provider environment variables:

- `OPENAI_API_KEY`: required for `--provider openai`
- `OPENAI_MODEL`: optional default model for `openai`
- `OLLAMA_MODEL`: optional default model for `ollama`
- `OLLAMA_BASE_URL`: optional Ollama chat endpoint, default `http://localhost:11434/api/chat`
- `ASHEX_ALLOW_LARGE_MODELS=1`: optional override if you intentionally want to bypass local-model memory guardrails

Guarded mode examples:

```bash
swift run ashex --approval-mode guarded 'shell: pwd'
swift run ashex --approval-mode guarded
```

In guarded mode:

- shell commands require approval
- filesystem writes and directory creation require approval
- read-only filesystem operations continue without prompting

TUI controls:

- `Tab`: cycle focus between launcher, settings/history panels, and input
- `Up/Down` or `j/k`: move through launcher or panel selections
- `Enter`: open the selected item or submit the current input
- `Esc` or `Left`: back out, cancel, or quit
- `y` / `n`: approve or deny guarded actions

## Runtime boundary

The CLI is intentionally only a presentation adapter. `AgentRuntime` exposes `run(_:) -> AsyncStream<RuntimeEvent>`, which is the intended boundary for future SwiftUI integration.

## Current model behavior

`MockModelAdapter` remains the fastest local test path. `OpenAIResponsesModelAdapter` and `OllamaChatModelAdapter` add real remote and local-provider paths while keeping the same runtime loop and typed `ModelAction` contract. The runtime also repairs malformed tool calls when safe and breaks repeated read-only local-model loops by returning the last good tool result.
