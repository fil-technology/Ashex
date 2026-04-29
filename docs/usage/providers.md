# Provider Guide

Ashex can run against local, hosted, and mock providers. You can change the active provider from `Assistant Setup` in the TUI, through first-run onboarding, or with CLI flags.

## Recommended Setup

```bash
ashex onboard
```

The onboarding flow lets you choose a provider, choose or type a model, install local models for `esh` or Ollama, save hosted-provider API keys in local secrets JSON, and skip anything you want to configure later.

## Provider Options

- `mock`: offline adapter for testing the UI and tool flow without a real model.
- `openai`: hosted OpenAI provider.
- `anthropic`: hosted Claude provider.
- `esh`: local `esh` runtime with installed MLX or GGUF models.
- `ollama`: local Ollama provider.
- `dflash`: experimental Apple-Silicon-local DFlash provider through `dflash-serve`.

## Esh

If `esh` is bundled with Ashex or discoverable through `optimization.esh.executablePath`, `ESH_EXECUTABLE`, or `PATH`, you can run it as a first-class provider:

```bash
ashex --provider esh --model your-installed-esh-model "list the files in this workspace"
```

If you omit a concrete model in the TUI, Ashex will try to use the first installed model reported by `esh capabilities`.

You can discover and install `esh` models from Ashex:

```bash
ashex model search qwen --provider esh
ashex model install Qwen/Qwen3-TTS-12Hz-0.6B-Base --provider esh --select
```

## OpenAI

```bash
export OPENAI_API_KEY=your_key_here
ashex --provider openai --model gpt-5.4-mini "list the files in this workspace"
```

You can also save the API key from `Assistant Setup`; Ashex stores it in `.ashex/secrets.json`.

## Anthropic

```bash
export ANTHROPIC_API_KEY=your_key_here
ashex --provider anthropic --model claude-sonnet-4.5 "summarize this repository"
```

You can also save the API key from `Assistant Setup`; Ashex stores it in `.ashex/secrets.json`.

## Ollama

```bash
ollama serve
ashex model install llama3.2 --provider ollama --select
ashex --provider ollama --model llama3.2 "list the files in this workspace"
```

`ashex model list --provider ollama` shows models reported by the local Ollama CLI. Assistant Setup also has an `Install Model` action that pulls an Ollama model and selects it for the next run.

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

- `OPENAI_API_KEY`: required for `--provider openai` unless saved in local secrets JSON.
- `ANTHROPIC_API_KEY`: required for `--provider anthropic` unless saved in local secrets JSON.
- `OPENAI_MODEL`: optional default model for `openai`.
- `ESH_MODEL`: optional default model for `esh`.
- `OLLAMA_MODEL`: optional default model for `ollama`.
- `OLLAMA_BASE_URL`: optional Ollama chat endpoint, default `http://localhost:11434/api/chat`.
- `OLLAMA_REQUEST_TIMEOUT_SECONDS`: optional Ollama request timeout override for slower agent-mode calls. The built-in default is 300 seconds.
- `DFLASH_MODEL`: optional default model for `dflash`.
- `DFLASH_BASE_URL`: optional DFlash server endpoint, default `http://127.0.0.1:8000`.
- `ASHEX_ALLOW_LARGE_MODELS=1`: bypass local-model memory guardrails.

## Secret Storage

- Environment variables take precedence over saved local secrets.
- API keys entered in the TUI are stored in `.ashex/secrets.json` for the selected workspace.
- Older SQLite-stored provider secrets are migrated forward automatically when read.
