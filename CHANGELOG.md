# Changelog

All notable changes to this project will be documented in this file.

The format is loosely based on Keep a Changelog and uses a simple `Added`, `Changed`, and `Fixed` grouping.

## Unreleased

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
