# Ashex Production Refinement Roadmap

This roadmap starts after the completion of the foundation and production-shaping milestones in [`implementation-phases.md`](implementation-phases.md) and [`production-milestones.md`](production-milestones.md).

The goal now is not to add another broad MVP checklist. The goal is to close the behavioral gap between Ashex's current harness architecture and the day-to-day reliability of stronger coding agents.

## Current Position

Ashex already has:

- a reusable single-agent runtime
- prompt building, context preparation, compaction, workspace snapshots, and working memory
- phased execution with exploration, planning, mutation, and validation
- inspect-before-mutate enforcement
- filesystem, git, shell, and patch-style edit workflows
- typed tool contracts across embedded tools plus bundled installable tool packs for `swiftpm`, `ios_xcode`, and `python`
- persistence, history, restart recovery, recent workspaces, and a TUI
- guarded approvals and bounded delegated subtasks

The remaining work is refinement work: making the agent choose the right files earlier, validate more intelligently, plan multi-file changes more deliberately, stay coherent over long sessions, and coordinate delegated work more effectively.

Recent architecture learnings we are now folding in:

- keep sandbox policy separate from approval policy
- keep the runtime structured so session, harness, and execution "hands" can evolve independently
- prefer rule-based execution policy over ad-hoc command checks

## Current Refinement Status

- Phase 1 is now completed:
  - exploration targets are now persisted in working memory
  - pending exploration targets are tracked as files and roots are inspected
  - deprioritized exploration paths are now persisted so the harness can remember what not to widen into without new evidence
  - history and prompts now surface that exploration state
  - the CLI/TUI now surface structured exploration updates instead of relying only on raw transcript lines
  - workspace snapshots now persist project markers plus likely source/test roots so exploration is anchored to repo shape instead of only broad top-level entries
- Phase 2 has started:
  - validation can now proactively execute checks instead of only gating completion
  - validation plans can include git diff/status, read-back checks, and workspace-aware build/test checks for SwiftPM, JavaScript package managers, Rust, and Go projects
- Safety hardening has started:
  - workspace sandbox modes now distinguish read-only, workspace-write, and danger-full-access semantics inside Ashex
  - protected workspace paths are now enforced separately from approval prompts
  - shell command policy now supports explicit allow / prompt / deny rules
  - config policy can now be layered from a global config and a project-local config with project precedence
  - network policy is now a first-class execution rule for shell commands
- history loading now uses a session inspection boundary instead of reaching into persistence call-by-call from the TUI
- Delegation coordination has improved:
  - delegated subtasks now have explicit assignment role/goal events
  - delegated work now returns a visible handoff summary plus remaining items
  - delegated handoffs now feed carry-forward notes and recommended follow-up paths back into working memory
  - bounded read-only parallel subagents can now be launched for exploration and validation lanes when the task has enough meaningful scoped targets
- Multi-file patch planning has started:
  - working memory now persists a planned change set and patch objectives
  - the runtime emits visible patch-plan updates during planning and mutation
- Long-session coherence has improved:
  - working memory now persists carry-forward notes to preserve useful findings across later steps and resumed history views
- The remaining refinement work below is still active

## Refinement Phase 1: Deeper Exploration And File Targeting

Status: completed

Goal: make Ashex inspect the right parts of a codebase before mutating anything.

Work:

- strengthen task-type-aware repo preflight before mutation
- improve file targeting with better use of `find_files`, `search_text`, `read_text_file`, and read-only git context
- bias exploration toward likely entry points for bug fixes, features, refactors, docs tasks, and shell-heavy tasks
- keep explored files, rejected paths, and likely next targets in working memory
- make exploration more visible in the TUI than raw transcript lines alone

Exit criteria:

- larger coding tasks reliably inspect relevant files before edits
- explored file sets are visible to the user
- file targeting is more selective than broad repo scanning

## Refinement Phase 2: Stronger Validation Execution

Goal: make Ashex validate work more like a real coding assistant instead of mostly suggesting validation.

Work:

- choose validation actions by task type and observed mutations
- prefer `git diff`, targeted reads, builds, tests, and shell-based verification where relevant
- add explicit validation execution paths for code edits, docs changes, shell tasks, and git tasks
- persist validation outcomes in working memory and final summaries
- block weak "done" states when relevant validation was skipped or failed

Exit criteria:

- changed code is routinely followed by meaningful validation
- validation results are persisted and summarized clearly
- final answers reflect whether work is verified, partially verified, or unverified

## Refinement Phase 3: Richer Multi-File Patch Planning

Goal: make multi-file changes feel deliberate instead of like a series of isolated edits.

Work:

- add a pre-mutation patch plan for larger edits
- group intended file changes into structured change sets
- store per-file intent, expected effect, and status
- improve diff summaries for multi-file work
- surface pending versus completed file changes during the run

Exit criteria:

- larger tasks produce explicit multi-file plans before edits
- users can see what files are expected to change and why
- final summaries can explain multi-file edits coherently

## Refinement Phase 4: Stronger Long-Session Behavior

Goal: improve quality and stability across long-running or resumed sessions.

Work:

- improve compaction quality using validated outcomes, file summaries, and resolved steps
- reduce repeated stale context and duplicate file-read history more aggressively
- strengthen working memory with durable findings, unresolved issues, assumptions, and validation status
- improve session resume so reopened runs preserve the distilled state that matters
- show compacted and clipped history more transparently in the UI

Exit criteria:

- long sessions degrade more gracefully
- resumed sessions retain important task state without replaying too much raw transcript
- compacted history remains understandable and inspectable

## Refinement Phase 5: Advanced Multi-Agent Orchestration

Goal: move from bounded delegated subtasks toward a more capable but still controlled multi-agent model.

Work:

- strengthen delegated task scoping, ownership, and result integration
- make subagent usage more task-aware instead of generic
- allow safe parallel delegated exploration and validation where appropriate
- preserve clear auditability of what each subagent did
- keep approvals, persistence, and workspace safety consistent across delegated work

Exit criteria:

- subagents are useful for real coding subtasks without creating chaos
- delegated work remains bounded, inspectable, and easy to merge back
- multi-agent behavior improves throughput without weakening safety or clarity

## Recommended Order

1. Deeper exploration and file targeting
2. Stronger validation execution
3. Richer multi-file patch planning
4. Stronger long-session behavior
5. Advanced multi-agent orchestration

## What "Closer To Codex-Class" Means

Ashex should feel meaningfully closer to stronger coding agents when it can do the following consistently:

- inspect the right files before editing
- choose a sensible validation path after changes
- plan and explain multi-file work clearly
- stay coherent across longer sessions
- delegate bounded subtasks without losing control of the overall task

## Relationship To Existing Docs

- [`implementation-phases.md`](implementation-phases.md) tracks the broader product and build history
- [`production-milestones.md`](production-milestones.md) tracks the completed production-foundation milestones
- [`../release/production-readiness-checklist.md`](../release/production-readiness-checklist.md) tracks the concrete remaining production-grade checklist
- this file tracks the next refinement path from "production-shaped" toward a stronger day-to-day coding agent
