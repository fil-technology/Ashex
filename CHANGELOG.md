# Changelog

All notable changes to this project will be documented in this file.

The format is loosely based on Keep a Changelog and uses a simple `Added`, `Changed`, and `Fixed` grouping.

## Unreleased

## v0.2.18 - 2026-04-22

### Added

- Telegram and TUI run visibility for plans, todos, patch plans, changed files, and delegated subagent handoffs.
- Deterministic workspace commands across Telegram, TUI, and one-shot CLI flows.
- Last-run inspection summaries with patch status, validation confidence, remaining work, and subagent audit trails.
- Per-file patch intent/status tracking for pending, inspected, and completed file work.
- Framework-aware validation planning for Python, Ruby, and containerized projects.

### Changed

- Long-session compaction now carries durable working-memory details forward.
- Validation summaries distinguish attempted, passed, failed, and partial verification more clearly.
- Telegram progress verbosity is configurable per chat.

### Fixed

- Simple workspace listing and folder creation avoid unnecessary model calls.
- Repeated read-only tool loops now return a user-facing result summary.

### Added

- phased runtime execution with exploration, planning, mutation, and validation
- Telegram daemon connector with per-chat controls, thread switching, stats toggles, and safe reasoning summaries
- multimodal Telegram ingestion for images and audio with normalized attachment context
- local and remote provider support across mock, Ollama, OpenAI, Anthropic, DFlash, and the `esh` bridge seam
- Ash optimization adoption seam and local optimized execution bridge for supported local setups
- time zone-aware cron jobs
- docs reorganization under `docs/` and curated `.codex/` project guidance

### Changed

- stronger exploration targeting now persists focus and deprioritized paths
- TUI and CLI now surface structured exploration state instead of only raw transcript lines
- README now documents the grouped docs layout and public-release guidance

### Fixed

- direct-chat handling now strips leaked `<think>` blocks and rejects raw tool transcript echoes
- Telegram reply parsing is more resilient to empty structured replies and leaked reasoning text
- local script runtime artifacts are now ignored by git
- default CLI workspaces now use `~/Ashex/DefaultWorkspace` instead of the current project directory
