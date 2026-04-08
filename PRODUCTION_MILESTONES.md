# Ashex Production Milestones

This file tracks the remaining work to move Ashex from a serious local MVP toward a more production-ready coding agent.

## Milestone 1: Smarter Exploration

- [x] Add a task-aware exploration strategy that suggests concrete inspect/search/read sequences
- [x] Bias coding tasks toward `find_files`, `search_text`, `read_text_file`, and read-only git inspection
- [x] Use workspace snapshot facts to improve exploration guidance
- [x] Verify with targeted runtime and unit tests

## Milestone 2: Stronger Validation

- [x] Add task-type-aware validation policies after edits
- [x] Prefer `git diff`, focused reads, tests, and builds where relevant
- [x] Prevent weak completion when validation is missing for mutation-heavy tasks
- [x] Verify with targeted runtime and unit tests

## Milestone 3: First-Class Patch/Edit Workflow

- [x] Add a structured patch/edit tool flow instead of relying mainly on raw writes and replaces
- [x] Improve diff-native summaries of edits
- [x] Make per-file changes easier to inspect in the TUI/history
- [x] Verify with targeted runtime and unit tests

## Milestone 4: Better Long-Context Handling

- [x] Strengthen working memory quality for long coding tasks
- [x] Improve compaction and deduplication quality beyond the current simple strategy
- [x] Improve session resume continuity across long threads
- [x] Verify with targeted runtime and unit tests

## Milestone 5: Large-Task Reliability

- [x] Improve decomposition and stalled-loop recovery for bigger tasks
- [x] Detect weak plans and unproductive retries earlier
- [x] Improve final summaries with changed files, rationale, validation, and remaining work
- [x] Verify with targeted runtime and unit tests

## Milestone 6: Secrets, Safety, and Sandboxing

- [x] Move provider secrets to a safer local storage mechanism
- [x] Tighten command and mutation safety boundaries
- [x] Improve approval auditing and safety UX
- [x] Verify with targeted runtime and unit tests

## Milestone 7: Multi-Workspace and Session UX

- [x] Add recent workspaces and clearer project/session switching
- [x] Improve per-workspace chat discovery and recovery
- [x] Make multi-project usage feel first-class without weakening workspace isolation
- [x] Verify with targeted runtime and UI tests

## Milestone 8: Bounded Subagents

- [x] Add delegated subtasks on top of the single-agent harness
- [x] Keep delegated scope bounded by files, context, and task depth
- [x] Preserve the existing persistence and approval model
- [x] Verify with targeted runtime and unit tests

## After These Milestones

The production-foundation milestones above are complete.

The next stage is refinement work:

- deeper exploration and file targeting
- stronger validation execution
- richer multi-file patch planning
- stronger long-session behavior
- more advanced multi-agent orchestration

See `PRODUCTION_REFINEMENT_ROADMAP.md` for the next-stage roadmap.
