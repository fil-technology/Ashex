# Documentation Map

This folder keeps long-form guides, plans, research notes, and release material out of the project root.

For installation and first use, start with the root [README](../README.md).

## Usage Guides

- [Provider guide](usage/providers.md): OpenAI, Anthropic, Ollama, DFlash, environment variables, and secret storage.
- [Daemon and Telegram guide](usage/daemon-telegram.md): background daemon, Telegram setup, cron jobs, execution modes, and access control.
- [Configuration and safety guide](usage/configuration.md): CLI options, sandbox policy, guarded mode, config files, and TUI controls.

## Architecture

- [Runtime and tools guide](architecture/runtime-and-tools.md): package layout, core tools, installable tool packs, runtime boundaries, memory, and current limitations.

## Roadmaps

- [Implementation phases](roadmap/implementation-phases.md): original MVP and production-foundation buildout phases.
- [Production milestones](roadmap/production-milestones.md): completed production-shaping milestone history.
- [Production refinement roadmap](roadmap/production-refinement-roadmap.md): current phased implementation plan.

## Release

- [Release maintenance guide](release/maintenance.md): packaging, binary-first Homebrew formula generation, and smoke checks.
- [Production readiness checklist](release/production-readiness-checklist.md): concrete production checklist.
- [Upcoming release prep](release/upcoming-release-prep.md): release-prep checklist and notes.

## Connector And Provider Notes

- [Daemon and Telegram MVP notes](connectors/daemon-telegram-mvp.md): implementation notes and follow-up plan for daemon/Telegram internals.
- [DFlash provider plan](providers/dflash-provider-plan.md): DFlash provider design and follow-up plan.

## Adoption And Research

- [Ash optimization adoption plan](adoption/ash-optimization-adoption-plan.md): Ash optimization adoption seam.
- [Ash to Ashex adoption plan](adoption/ash-to-ashex-adoption-plan.md): broader Ash-to-Ashex transfer plan.
- [oMLX evaluation](research/omlx-evaluation.md): oMLX evaluation notes.

## Codex Entry Point

For future Codex sessions, start in [`.codex/README.md`](../.codex/README.md) for a curated architecture and release overview.
