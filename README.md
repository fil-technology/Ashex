# Ashex MVP

Ashex is a minimal local agent runtime foundation for macOS, built as a small Swift package with a reusable core runtime and a thin CLI adapter.

## What this MVP includes

- A real single-agent loop with max-iteration and cancellation guards
- Exactly two tools: `filesystem` and `shell`
- Live streaming runtime events for CLI or future UI consumers
- SQLite persistence for threads, messages, runs, tool calls, and append-only events
- Restart normalization that marks previously running work as `interrupted`
- A replaceable model boundary with both mock and OpenAI-backed adapters

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

OpenAI-backed mode:

```bash
export OPENAI_API_KEY=your_key_here
swift run ashex --provider openai --model gpt-5.4-mini "list the files in this workspace"
```

CLI options:

- `--workspace PATH`: workspace root enforced by `WorkspaceGuard`
- `--storage PATH`: persistence directory, default `WORKSPACE/.ashex`
- `--max-iterations N`: loop limit, default `8`
- `--provider mock|openai`: model adapter selection, default `mock`
- `--model MODEL`: model name for provider-backed mode, default `gpt-5.4-mini`
- `--approval-mode trusted|guarded`: execution policy, default `trusted`

Guarded mode examples:

```bash
swift run ashex --approval-mode guarded 'shell: pwd'
swift run ashex --approval-mode guarded
```

In guarded mode:

- shell commands require approval
- filesystem writes and directory creation require approval
- read-only filesystem operations continue without prompting

## Runtime boundary

The CLI is intentionally only a presentation adapter. `AgentRuntime` exposes `run(_:) -> AsyncStream<RuntimeEvent>`, which is the intended boundary for future SwiftUI integration.

## Current model behavior

`MockModelAdapter` remains the fastest local test path. `OpenAIResponsesModelAdapter` adds a minimal real-provider path over the Responses API while keeping the same runtime loop and typed `ModelAction` contract.
