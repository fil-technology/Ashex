# Architecture Guide

## Primary Layers

- `Sources/AshexCore`: runtime loop, model adapters, tools, persistence, daemon routing, context handling, and working memory
- `Sources/AshexCLI`: CLI and TUI surfaces over the streamed runtime events
- `Tests/AshexCoreTests`: behavioral coverage for runtime, connectors, persistence, planning, and provider adapters

## Key Runtime Files

- `Sources/AshexCore/AgentRuntime.swift`: main phased execution flow
- `Sources/AshexCore/ModelAdapter.swift`: provider adapters and direct-chat behavior
- `Sources/AshexCore/ToolExecutor.swift`: central tool validation and dispatch path
- `Sources/AshexCore/Prompting.swift`: prompt assembly, working-memory rendering, and context compaction helpers
- `Sources/AshexCore/SQLitePersistence.swift`: persisted runs, events, settings, workspace snapshots, and working memory

## Daemon And Telegram

- `Sources/AshexCore/Daemon/RunDispatcher.swift`: dispatches inbound requests into the normal runtime stream
- `Sources/AshexCore/Daemon/DaemonSupervisor.swift`: command handling, per-chat toggles, reply decoration, and run orchestration
- `Sources/AshexCore/Connectors/Telegram/TelegramConnector.swift`: Telegram polling, normalization, and outbound sends

## Planning And Refinement

- `Sources/AshexCore/TaskPlanning.swift`: task classification and default plans
- `Sources/AshexCore/ExplorationStrategy.swift`: exploration targeting and query suggestions
- `Sources/AshexCore/PatchPlanningStrategy.swift`: multi-file patch intent and objectives
- `Sources/AshexCore/ValidationStrategy.swift`: validation planning and auto-checks

## Supporting Docs

- [`../../docs/README.md`](../../docs/README.md): complete docs map
- [`../../docs/roadmap/production-refinement-roadmap.md`](../../docs/roadmap/production-refinement-roadmap.md): current phased implementation plan
