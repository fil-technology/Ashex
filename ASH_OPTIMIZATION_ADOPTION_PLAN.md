# Ash Optimization Adoption

This branch adds the first Ashex-side adoption seam for the optimization work that already exists in the `esh` / Ash-adjacent MLX codebase:

- `raw`
- `turbo`
- `triattention`
- `auto`

## Current state

Ashex already has:

- automatic context compaction
- deduplication of repeated tool-read summaries during compaction
- persisted compaction records
- token saved / token used inspection

Ashex does not yet have:

- real KV-cache reuse
- prompt cache artifact export/import
- `triattention`
- a runtime bridge that executes model requests through `esh`

## What this branch adds

## 1. Shared optimization vocabulary in Ashex

Ashex now has its own config and policy layer for:

- optimization backend
- optimization intent
- optimization mode
- `esh` bridge settings

That lets Ashex reason about Ash-style optimization without hard-coding it into the current runtime loop.

## 2. A bridge-friendly recommendation policy

Ashex now resolves an optimization mode using local context:

- remote providers default to `raw`
- local code / agent tasks prefer `triattention` when calibration exists
- local broader multi-step tasks prefer `turbo`
- chat stays `raw`

This mirrors the spirit of the `KVModePolicy` in `esh` while staying additive and provider-agnostic in Ashex.

## 3. A working doctor / resolve CLI

Commands:

```bash
swift run ashex optimize doctor
swift run ashex optimize resolve --task "Implement a large multi-step local code refactor"
```

These commands currently:

- read Ashex optimization config
- discover the `esh` executable when available
- resolve `ESH_HOME`
- compute the expected triattention calibration path for the selected model
- report whether calibration is present
- print the recommended optimization mode and reason

## Suggested config

```json
{
  "optimization": {
    "enabled": true,
    "backend": "esh",
    "mode": "auto",
    "intent": "agentrun",
    "esh": {
      "executablePath": "/opt/homebrew/bin/esh",
      "homePath": "/Users/you/.esh"
    }
  }
}
```

## Recommended next phase

The next safe integration step is not to copy MLX runtime code into Ashex yet. Instead:

1. Add an optional Ashex model adapter that shells out to `esh` for local optimized inference only.
2. Keep current OpenAI / Anthropic / Ollama adapters untouched.
3. Use the new optimization policy to decide when Ashex should ask the bridge for `raw`, `turbo`, or `triattention`.
4. Only after that is stable, consider importing cache artifact logic more directly.

## Why bridge-first is safer

- Ash / `esh` already owns the MLX + bridge + calibration details.
- Ashex already owns tools, approvals, planning, persistence, and connector UX.
- A bridge keeps the responsibilities separated and avoids a large runtime rewrite.
