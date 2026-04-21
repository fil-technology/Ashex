# Provider Guide

Ashex can run against local, hosted, and mock providers. You can change the active provider from `Assistant Setup` in the TUI, through first-run onboarding, or with CLI flags.

## Recommended Setup

```bash
ashex onboard
```

The onboarding flow lets you choose a provider, choose or type a model, save hosted-provider API keys in macOS Keychain, and skip anything you want to configure later.

## Provider Options

- `mock`: offline adapter for testing the UI and tool flow without a real model.
- `openai`: hosted OpenAI provider.
- `anthropic`: hosted Claude provider.
- `ollama`: local Ollama provider.
- `dflash`: experimental Apple-Silicon-local DFlash provider through `dflash-serve`.

## OpenAI

```bash
export OPENAI_API_KEY=your_key_here
ashex --provider openai --model gpt-5.4-mini "list the files in this workspace"
```

You can also save the API key from `Assistant Setup`; Ashex stores it in macOS Keychain.

## Anthropic

```bash
export ANTHROPIC_API_KEY=your_key_here
ashex --provider anthropic --model claude-sonnet-4.5 "summarize this repository"
```

You can also save the API key from `Assistant Setup`; Ashex stores it in macOS Keychain.

## Ollama

```bash
ollama serve
ollama pull llama3.2
ashex --provider ollama --model llama3.2 "list the files in this workspace"
```

Ashex applies local-model memory guardrails for Ollama based on the Mac's available RAM and the installed model size. If you intentionally want to override that guardrail:

```bash
ASHEX_ALLOW_LARGE_MODELS=1 ashex --provider ollama --model your-large-model
```

## DFlash

```bash
dflash-serve --model Qwen/Qwen3.5-4B --port 8000
export DFLASH_BASE_URL=http://127.0.0.1:8000
ashex --provider dflash --model Qwen/Qwen3.5-4B "say hello"
```

DFlash is direct-chat only for now, so full tool-calling agent mode should stay on `openai`, `anthropic`, `ollama`, or `mock`.

More design notes live in [DFlash provider plan](../providers/dflash-provider-plan.md).

## Environment Variables

- `OPENAI_API_KEY`: required for `--provider openai` unless saved in Keychain.
- `ANTHROPIC_API_KEY`: required for `--provider anthropic` unless saved in Keychain.
- `OPENAI_MODEL`: optional default model for `openai`.
- `OLLAMA_MODEL`: optional default model for `ollama`.
- `OLLAMA_BASE_URL`: optional Ollama chat endpoint, default `http://localhost:11434/api/chat`.
- `OLLAMA_REQUEST_TIMEOUT_SECONDS`: optional Ollama request timeout override for slower agent-mode calls.
- `DFLASH_MODEL`: optional default model for `dflash`.
- `DFLASH_BASE_URL`: optional DFlash server endpoint, default `http://127.0.0.1:8000`.
- `ASHEX_ALLOW_LARGE_MODELS=1`: bypass local-model memory guardrails.

## Secret Storage

- Environment variables take precedence over saved local secrets.
- API keys entered in the TUI are stored in macOS Keychain.
- Older SQLite-stored provider secrets are migrated forward automatically when read.
