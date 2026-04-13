# DFlash Provider Integration Plan

## Goal

Add an experimental DFlash-backed local provider to Ashex for Apple Silicon, using the current provider and daemon architecture without rewriting the runtime.

This plan is based on:

- `bstnxbt/dflash-mlx`: https://github.com/bstnxbt/dflash-mlx
- `dflash-mlx` README: https://raw.githubusercontent.com/bstnxbt/dflash-mlx/main/README.md
- `dflash-mlx` packaging: https://raw.githubusercontent.com/bstnxbt/dflash-mlx/main/pyproject.toml

## Why This Repo Is The Best First Fit

Compared with lower-level DFlash ports, `bstnxbt/dflash-mlx` appears more practical for Ashex because it already exposes:

- a CLI entrypoint: `dflash`
- a local server entrypoint: `dflash-serve`
- streaming support
- OpenAI-compatible client support
- fallback to standard autoregressive generation when no draft is available

That makes it a better candidate for an additive provider integration.

## What We Should Add First

The safest MVP is:

1. Add a new experimental provider mode: `dflash`
2. Treat it as Apple-Silicon-only and local-only
3. Integrate through `dflash-serve` first, not by embedding Python internals
4. Support direct chat first
5. Keep full tool-calling agent mode on existing providers until structured-output reliability is proven

This should be framed as:

- fast local chat backend
- good fit for Telegram and daemon chat
- not yet the default coding-agent backend

## Why We Should Not Reuse The Current OpenAI Adapter Directly

Ashex currently has:

- `OpenAIResponsesModelAdapter` in `Sources/AshexCore/ModelAdapter.swift`
- provider selection in `Sources/AshexCLI/CLIProgram.swift`

The existing OpenAI adapter targets the OpenAI `responses` API shape and expects strict JSON-schema responses for both:

- tool-calling actions
- direct chat replies

Even if `dflash-serve` is OpenAI-compatible, it is more likely to emulate chat-completions style endpoints than the OpenAI `responses` API contract.

So the clean integration is:

- do not overload the existing `openai` provider
- add a separate DFlash adapter with its own request/response handling

## Proposed Architecture

### Phase 1: Direct Chat Only

Add:

- `DFlashServerModelConfiguration`
- `DFlashServerModelAdapter`

Target file:

- `Sources/AshexCore/ModelAdapter.swift`

Responsibilities:

- implement `DirectChatModelAdapter`
- send a plain chat request to a local `dflash-serve` endpoint
- return a single assistant string

Use cases:

- Telegram casual chat
- daemon `assistant_only` conversations
- TUI direct conversation mode later if desired

Do not support in phase 1:

- tool calls
- schema-driven model actions
- full coding-agent loop

### Phase 2: Optional Streaming For Connectors

Once direct chat is stable:

- add streaming support from `dflash-serve`
- wire it into Telegram edited-message streaming
- reuse the existing connector abstraction instead of special-casing DFlash

That gives:

- fast local generation
- Telegram partial responses
- no change to core tool execution semantics

### Phase 3: Evaluate Structured Agent Mode

Only after the provider is stable in direct chat:

- test whether DFlash can reliably produce strict structured JSON
- if yes, add full `ModelAdapter.nextAction(for:)`
- if not, keep it as a chat-only backend

This should be a measured decision, not assumed up front.

## Config Shape

Add a DFlash config section inside user config.

Suggested fields:

```json
{
  "dflash": {
    "enabled": false,
    "baseURL": "http://127.0.0.1:8000",
    "model": "Qwen/Qwen3.5-9B",
    "draftModel": null,
    "mode": "direct_chat",
    "requestTimeoutSeconds": 120,
    "appleSiliconOnly": true
  }
}
```

Notes:

- `enabled` is optional if provider selection is sufficient, but useful for onboarding
- `draftModel` should remain optional because the upstream server can auto-resolve drafts
- `mode` should start as `direct_chat`
- `baseURL` should default to a local loopback endpoint

## CLI Changes

Target file:

- `Sources/AshexCLI/CLIProgram.swift`

Add support for:

- `--provider dflash`
- optional environment variable `DFLASH_BASE_URL`
- optional environment variable `DFLASH_MODEL`

Provider selection logic should:

- reject unsupported hosts cleanly
- fail early on non-Apple-Silicon hardware
- produce a clear message when `dflash-serve` is unavailable

Example:

```bash
dflash-serve --model Qwen/Qwen3.5-9B --port 8000
swift run ashex --provider dflash --model Qwen/Qwen3.5-9B
```

## Recommended Adapter Contract

Add a dedicated configuration and adapter instead of hiding this under `openai`.

Suggested surface:

```swift
public struct DFlashServerModelConfiguration: Sendable {
    public let baseURL: URL
    public let model: String
    public let timeoutSeconds: Int
}

public struct DFlashServerModelAdapter: ModelAdapter {
    public let providerID = "dflash"
}
```

For phase 1:

- `nextAction(for:)` can explicitly throw a provider limitation error
- `directReply(history:systemPrompt:)` should be fully supported

That keeps the runtime honest and avoids pretending it can do tool-mode work that it cannot yet perform.

## Telegram Fit

DFlash is especially attractive for Telegram because:

- direct chat is already split from tool-driven workspace tasks in `DaemonSupervisor`
- casual Telegram prompts now route into `RunRequest.Mode.directChat`
- DFlash can slot into that path without weakening sandbox or approval semantics

This means we can eventually support:

- fast local chat over Telegram
- native typing indicator
- edited-message partial streaming

without changing the policy boundary around tools.

## Onboarding Fit

In the TUI setup flow, DFlash can be presented as:

- `Provider: DFlash (Experimental)`
- requires Apple Silicon
- requires `pip install dflash-mlx`
- requires local `dflash-serve`

The setup helper should verify:

1. the host is Apple Silicon
2. the server responds
3. the selected model is reachable

This is better than hiding the dependency behind a vague provider name.

## File-Level Implementation Plan

### 1. Provider Core

Update:

- `Sources/AshexCore/ModelAdapter.swift`

Add:

- `DFlashServerModelConfiguration`
- `DFlashServerModelAdapter`
- request/response DTOs for the chosen server endpoint

### 2. CLI Wiring

Update:

- `Sources/AshexCLI/CLIProgram.swift`

Add:

- `case "dflash"` in provider selection
- model default handling
- environment-variable support
- startup validation messaging

### 3. User Config

Update:

- `Sources/AshexCore/UserConfig.swift`

Add:

- `DFlashConfig`
- config decoding defaults

### 4. TUI Setup

Update:

- `Sources/AshexCLI/TUIApp.swift`

Add:

- provider option for DFlash
- setup copy for local server requirements
- connectivity test action if practical

### 5. Daemon / Telegram

No architecture change required for phase 1.

The daemon should automatically benefit when:

- provider is `dflash`
- message intent resolves to direct chat

## Testing Plan

### Unit Tests

Add tests for:

- DFlash direct chat response parsing
- provider selection for `--provider dflash`
- unsupported non-Apple-Silicon behavior
- server-unreachable error handling

### Integration Tests

Add mock-server tests for:

- direct chat happy path
- malformed server payload
- timeout behavior

### Manual Verification

Manual smoke flow:

1. start `dflash-serve`
2. launch `ashex --provider dflash`
3. ask a casual question in TUI
4. run Telegram daemon in `assistant_only`
5. verify Telegram direct chat uses DFlash successfully

## Recommended Scope Decision

### Build Now

- experimental DFlash provider
- direct chat only
- local server integration
- Telegram / daemon compatibility through existing direct-chat path

### Defer

- tool-calling agent mode on DFlash
- structured JSON action generation
- Linux support
- full fallback orchestration between DFlash and other providers
- deep Python embedding

## Bottom Line

The best first Ashex integration is:

- `dflash-serve` as a local Apple-Silicon chat backend
- `--provider dflash`
- direct-chat mode first
- connector reuse, not runtime rewrites

This is aligned with the current Ashex architecture and gives us the fastest route to a materially better local Telegram and daemon experience.
