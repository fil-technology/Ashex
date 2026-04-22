# Deep Agent Implementation Tracker

This file tracks the current Telegram/workspace reliability push. Mark each phase when implementation and validation are complete.

## Phase 1: Workspace Transparency

- [x] Show the active daemon workspace path from Telegram.
- [x] Include the active workspace in `/status`.
- [x] Add a deterministic `/pwd` command.

## Phase 2: Simple Filesystem Fast Paths

- [x] Add deterministic `/ls [path]` support.
- [x] Add deterministic `/mkdir path` support with sandbox checks.
- [x] Short-circuit simple natural-language file listing requests.
- [x] Short-circuit simple natural-language create-folder requests when a path is provided.
- [x] Fail fast for Telegram folder creation when execution policy is `assistant_only`.

## Phase 3: Cleaner Loop Recovery

- [x] Keep repeated read-only call protection.
- [x] Replace the internal “same read-only call” final text with a user-facing result summary.

## Phase 4: Model Timeout Reduction

- [x] Avoid model calls for simple list/create-folder requests.
- [x] Add progress replies for long-running Telegram model requests.
- [x] Add a Telegram-visible hint when Ollama timeout settings are likely too low for the selected model.

## Phase 5: Workspace Selection

- [x] Add Telegram `/workspace` readout/help.
- [x] Add a guarded way to switch daemon workspace or document that the daemon must be restarted with `--workspace`.
- [x] Show the daemon startup command needed for the current workspace in setup docs.

## Phase 6: Validation

- [x] Add unit tests for `/pwd`, `/ls`, and `/mkdir`.
- [x] Add unit tests for natural-language simple workspace commands.
- [x] Run focused daemon/connector tests.
- [x] Run full SwiftPM tests when the focused suite is green.

## Phase 7: CLI Parity

- [x] Route TUI `/ls` and `/mkdir` through the shared workspace executor.
- [x] Route one-shot CLI `/pwd`, `/workspace`, `/ls`, and `/mkdir` through the shared workspace executor.
- [x] Keep CLI and Telegram workspace commands under the same sandbox checks.

## Phase 8: Live Run Visibility

- [x] Surface task plans in Telegram.
- [x] Surface current todo/checklist state in Telegram.
- [x] Surface step start and completion updates in Telegram.
- [x] Surface patch plans and changed files in Telegram.
- [x] Surface delegated subagent assignments and handoffs in Telegram.
- [x] Add per-chat controls to choose quiet versus verbose progress updates.

## Phase 9: Product-Grade Deep Agent Controls

- [x] Add CLI and Telegram commands for last-run inspection.
- [x] Add resumable run summaries with changed files, validation, and remaining work.
- [x] Add stronger approval/status cards for Telegram and TUI parity.
- [x] Add configurable progress verbosity across CLI, TUI, and Telegram.

## Phase 10: Deep Agent Reliability

- [x] Improve multi-file patch status with pending/completed per file.
- [x] Improve long-session resume summaries from working memory.
- [x] Improve subagent audit trails and ownership boundaries.
- [x] Add validation confidence labels to final summaries.
