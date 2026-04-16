# oMLX Evaluation

## Executive Verdict

oMLX is real. It already ships the three things this repo does not currently own natively: block-level prefix reuse, SSD-backed persistent KV storage, and continuous batching on Apple Silicon.

This codebase already has the better agent architecture: thread and run lifecycle, persistence, working memory, routing, and backend seams are all Ashex-owned rather than model-server-owned.

So the right answer is not "replace Ashex with oMLX." That would be a flexibility regression.

The right answer is: use oMLX as an optional MLX backend if you want its runtime wins now, and copy its cache architecture ideas into Ashex abstractions over time.

Direct adoption would lock too much of the future to an MLX-specific server. Ignoring it would also be wrong, because its cache implementation is materially ahead of what is present here today.

## What My Codebase Already Has

- Backend seam exists. [`ModelAdapter`](/Users/sviatoslavfil/Development/Fil.Technology/Codex-based/Agents/Eshex/Source/Sources/AshexCore/ModelAdapter.swift:63) is the core abstraction, with `DirectChatModelAdapter` and `TaskPlanningModelAdapter` built on top of it.
- Agent and session lifecycle are already first-class. [`AgentRuntime`](/Users/sviatoslavfil/Development/Fil.Technology/Codex-based/Agents/Eshex/Source/Sources/AshexCore/AgentRuntime.swift:37) owns runs; [`runDirectChat`](/Users/sviatoslavfil/Development/Fil.Technology/Codex-based/Agents/Eshex/Source/Sources/AshexCore/AgentRuntime.swift:95) resumes threads by `threadID`; [`persistWorkingMemory`](/Users/sviatoslavfil/Development/Fil.Technology/Codex-based/Agents/Eshex/Source/Sources/AshexCore/AgentRuntime.swift:140) and [`persistTaskPlan`](/Users/sviatoslavfil/Development/Fil.Technology/Codex-based/Agents/Eshex/Source/Sources/AshexCore/AgentRuntime.swift:173) persist agent state.
- Persistence is broad, but it is transcript and workflow persistence, not native KV persistence. [`Persistence`](/Users/sviatoslavfil/Development/Fil.Technology/Codex-based/Agents/Eshex/Source/Sources/AshexCore/Persistence.swift:3) and [`SQLitePersistence`](/Users/sviatoslavfil/Development/Fil.Technology/Codex-based/Agents/Eshex/Source/Sources/AshexCore/SQLitePersistence.swift:17) store threads, messages, runs, steps, compactions, snapshots, tool calls, and events.
- Session restore today is logical restore, not runtime cache restore. [`resumeDirectChat`](/Users/sviatoslavfil/Development/Fil.Technology/Codex-based/Agents/Eshex/Source/Sources/AshexCore/AgentRuntime.swift:379) rebuilds context from stored messages, and [`processRunLoop`](/Users/sviatoslavfil/Development/Fil.Technology/Codex-based/Agents/Eshex/Source/Sources/AshexCore/AgentRuntime.swift:686) prepares fresh context each step.
- The only verified prefill-avoidance path is delegated to external `esh`. [`EshBridgeModelAdapter`](/Users/sviatoslavfil/Development/Fil.Technology/Codex-based/Agents/Eshex/Source/Sources/AshexCore/EshBridgeModelAdapter.swift:31) runs `esh cache build` and `esh cache load` via [`buildAndLoadCacheArtifact`](/Users/sviatoslavfil/Development/Fil.Technology/Codex-based/Agents/Eshex/Source/Sources/AshexCore/EshBridgeModelAdapter.swift:157). Ashex is not currently managing persistent KV assets itself.
- Compression and optimization hooks exist mostly as policy or config, not as a proven native runtime implementation in this repo. [`OptimizationBackend`](/Users/sviatoslavfil/Development/Fil.Technology/Codex-based/Agents/Eshex/Source/Sources/AshexCore/OptimizationSupport.swift:18) only exposes `.esh`, and [`ContextOptimizationAdvisor`](/Users/sviatoslavfil/Development/Fil.Technology/Codex-based/Agents/Eshex/Source/Sources/AshexCore/OptimizationSupport.swift:120) selects modes.
- Queueing exists at the agent and UI level, not as an inference batch scheduler. [`RunDispatcher`](/Users/sviatoslavfil/Development/Fil.Technology/Codex-based/Agents/Eshex/Source/Sources/AshexCore/Daemon/RunDispatcher.swift:13), [`TUIQueueing`](/Users/sviatoslavfil/Development/Fil.Technology/Codex-based/Agents/Eshex/Source/Sources/AshexCLI/TUIQueueing.swift:21), and [`ConnectorConversationMappingStore`](/Users/sviatoslavfil/Development/Fil.Technology/Codex-based/Agents/Eshex/Source/Sources/AshexCore/Routing/ConnectorConversationMappingStore.swift:34) are orchestration pieces, not shared decode scheduling.

## What oMLX Actually Implements

- oMLX is a hybrid product: CLI, app, and FastAPI inference server, not a thin library. Sources: [README](https://github.com/jundot/omlx/blob/main/README.md), [server.py](https://github.com/jundot/omlx/blob/main/omlx/server.py).
- Continuous batching is real in code, not just a claim. Sources: [scheduler.py](https://github.com/jundot/omlx/blob/main/omlx/scheduler.py), [engine/batched.py](https://github.com/jundot/omlx/blob/main/omlx/engine/batched.py).
- Tiered KV caching is real. Sources: [prefix_cache.py](https://github.com/jundot/omlx/blob/main/omlx/cache/prefix_cache.py), [paged_ssd_cache.py](https://github.com/jundot/omlx/blob/main/omlx/cache/paged_ssd_cache.py), [paged_cache.py](https://github.com/jundot/omlx/blob/main/omlx/cache/paged_cache.py).
- Persistent KV-to-disk is real. `PagedSSDCacheManager` scans persisted `.safetensors` blocks on startup and rebuilds its index. Source: [paged_ssd_cache.py](https://github.com/jundot/omlx/blob/main/omlx/cache/paged_ssd_cache.py).
- Prefill avoidance is real. The scheduler reconstructs prompt cache state from cached prefix blocks and tracks `cached_tokens` and `remaining_tokens`. Sources: [request.py](https://github.com/jundot/omlx/blob/main/omlx/request.py), [scheduler.py](https://github.com/jundot/omlx/blob/main/omlx/scheduler.py).
- Snapshotting for non-sliceable cache boundaries is also present. Source: [boundary_snapshot_store.py](https://github.com/jundot/omlx/blob/main/omlx/cache/boundary_snapshot_store.py).
- It exposes APIs that let Ashex keep its own orchestration layer. Source: [server.py](https://github.com/jundot/omlx/blob/main/omlx/server.py), which serves OpenAI-style `/v1/chat/completions`, `/v1/messages`, `/v1/responses`, and model endpoints.
- Its session model is weaker than Ashex's. oMLX is request and prefix-cache centric, not thread and run centric. Reuse is keyed by block hashes and token prefixes rather than by a first-class agent session abstraction.
- It is MLX-specific and architecture-constraining by design. Sources: [README](https://github.com/jundot/omlx/blob/main/README.md), [scheduler.py](https://github.com/jundot/omlx/blob/main/omlx/scheduler.py), [engine_pool.py](https://github.com/jundot/omlx/blob/main/omlx/engine_pool.py).

## Direct Comparison

| Capability | My stack | oMLX | Who wins | Notes |
| --- | --- | --- | --- | --- |
| prefill avoidance | Only verified through external `esh` bridge in [`EshBridgeModelAdapter`](/Users/sviatoslavfil/Development/Fil.Technology/Codex-based/Agents/Eshex/Source/Sources/AshexCore/EshBridgeModelAdapter.swift:157) | Native block-prefix reuse in scheduler and request cache flow | oMLX | oMLX is implemented; Ashex delegates |
| persistent KV reuse | Not found as an Ashex-owned runtime feature | SSD-backed block cache with startup reindex | oMLX | Biggest concrete gap |
| cache compression | Policy hooks exist; no native KV compression path proven in this repo | Real cache and runtime machinery, including TurboQuant-related runtime work | oMLX | Ashex is pointed here conceptually, not operationally |
| tiered cache | Not found | Hot memory plus cold SSD cache layers | oMLX | Real implementation |
| disk persistence | Strong transcript and run persistence via SQLite | Real KV block persistence to `.safetensors` | Split | Ashex wins for agent state; oMLX wins for inference state |
| continuous batching | Not found | Implemented via batched scheduler | oMLX | Material local-serving advantage |
| multi-session handling | Strong thread and run ownership in [`AgentRuntime`](/Users/sviatoslavfil/Development/Fil.Technology/Codex-based/Agents/Eshex/Source/Sources/AshexCore/AgentRuntime.swift:37) and routing stores | Request-centric reuse, weaker agent-session semantics | My stack | Keep Ashex authoritative |
| orchestration flexibility | High; clean adapter seam and agent-owned lifecycle | Server-shaped runtime with its own assumptions | My stack | Why direct adoption is a mistake |
| backend portability | Explicitly aligned with future multi-backend goals | MLX-only | My stack | oMLX is not portable |
| agent friendliness | Built for tools, memory, approvals, and thread state | API-compatible provider, but not an agent runtime | My stack | Keep Ashex in charge |
| implementation complexity | Smaller and easier to steer | Bigger, more capable, more coupled | Depends | oMLX wins on shipped runtime features; Ashex wins on maintainability |
| integration risk | Low if current architecture stays in control | High for direct adoption, moderate as optional backend | My stack | Optional-backend integration is the sane middle path |

## Best Path Forward

Use as optional backend.

oMLX is good enough to be worth using, but too opinionated to deserve control of the architecture. This repo already has the better long-term shape for a multi-backend agent system, and oMLX does not replace that. What it can do is serve as a high-performance MLX runtime behind the existing `ModelAdapter` seam, while Ashex keeps ownership of threads, runs, tool UX, persistence, and future non-MLX expansion. That gets real Apple Silicon wins without giving up architectural leverage.

## Minimal Implementation Plan

1. Add a runtime-capabilities surface to `ModelAdapter`: `supportsPersistentPrefixReuse`, `supportsDiskBackedCache`, `supportsContinuousBatching`, `supportsWarmSessionRestore`.
2. Add an `oMLXModelAdapter` that talks to oMLX's OpenAI-compatible endpoints and keeps all orchestration inside Ashex.
3. Benchmark `esh` vs `oMLX` with the same workloads and report TTFT, prefill time, decode tok/s, cache hit reuse rate, thread-switch latency, cold vs warm startup, memory use, and disk use.
4. If oMLX clearly wins on warm reuse and thread switching, keep it as an MLX-only backend option.
5. Separately copy the ideas, not the lock-in: block-hash cache identity, hot and cold cache layering, startup reindex, and boundary snapshot handling should eventually become backend-neutral concepts in Ashex.

## Code Changes I Should Make In My Repo

- Added: `docs/research/omlx-evaluation.md`
- Change: `Sources/AshexCore/ModelAdapter.swift` to expose runtime capability flags and telemetry hooks
- Add: `Sources/AshexCore/oMLXModelAdapter.swift`
- Change: `Sources/AshexCLI/CLIProgram.swift` to register an `omlx` provider or runtime option
- Change: `Sources/AshexCLI/UserConfig.swift` to add oMLX endpoint, model, and cache settings
- Add: `Sources/AshexCLI/BenchmarkCLI.swift` or equivalent benchmark command
- Add: `Tests/AshexCoreTests/oMLXModelAdapterTests.swift`

## Risks / Unknowns

- I did not find native MLX runtime ownership in this repo, so some planned capabilities may exist in sibling repos or in `esh`, but they are not present here.
- oMLX's strongest features are tightly coupled to MLX internals. If integration goes below the HTTP or API layer, that coupling comes with it.
- oMLX is substantial, but it is still ambitious infrastructure: custom scheduler logic, persistence machinery, and MLX-specific execution constraints create real operational risk.
- The decision still depends on measured wins. If oMLX does not materially improve TTFT, warm restore, and thread-switch latency on actual agent workloads, it is not worth even optional integration.
