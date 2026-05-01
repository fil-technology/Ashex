# Ashex Implementation Phases

This roadmap outlines the phases to reach a small but serious MVP for Ashex: a local single-agent system inspired by tools like Codex/OpenClaw, but intentionally narrower in scope, strongly typed, and built to grow cleanly over time.

The near-term goal is not to recreate a full OpenClaw clone. The goal is to deliver a usable vertical slice with a real agent loop, strict workspace boundaries, live event streaming, durable persistence, and clean runtime boundaries that can later plug into richer terminal and SwiftUI clients without refactoring the core.

## Phase 0: Foundation and Repo Setup

Goal: establish a clean, maintainable project skeleton.

- Initialize local git repository
- Create Swift package with clear target separation
- Define core domain types for threads, messages, runs, tools, events, and errors
- Set up basic README and project conventions
- Decide on local storage layout for runtime state
- Establish explicit boundaries between domain/runtime code and presentation adapters from day one

Exit criteria:

- Project builds locally
- Core modules exist and responsibilities are separated

## Phase 1: Minimal Agent Runtime

Goal: make the core single-agent loop real.

- Implement `AgentRuntime` to own run lifecycle
- Define structured `ModelAdapter` contract with two outcomes:
  - `final_answer`
  - `tool_call`
- Create initial run creation and state transitions
- Append user and assistant messages into runtime history
- Add max-iteration guard
- Add defensive error handling for model and runtime failures
- Keep model integration behind a narrow adapter so the initial implementation can use either a mock provider or a single real provider without changing runtime semantics

Exit criteria:

- A user prompt can drive a real loop
- The loop ends with a final answer, tool call, or failure state

## Phase 2: Workspace Safety and Tool System

Goal: add the first two tools behind strict boundaries.

- Implement `WorkspaceGuard` to enforce workspace-root-only access
- Implement `Tool` protocol and `ToolRegistry`
- Add `filesystem` tool with:
  - read text file
  - write text file
  - list directory
  - create directory
- Add `shell` tool with:
  - command execution in workspace
  - stdout/stderr capture
  - exit code reporting
  - timeout support
  - cancellation hook
- Ensure tool errors are structured and persisted

Exit criteria:

- Both tools work only inside the allowed workspace
- Tool results are appended as structured conversation artifacts

## Phase 3: Streaming Event Model

Goal: make the system observable in real time.

- Define typed runtime events suitable for both terminal and future SwiftUI clients:
  - run started
  - run state changed
  - status updates
  - tool call started
  - tool output chunk
  - tool call finished
  - message appended
  - final answer
  - error
  - run finished
- Expose runtime output as a stream the CLI or UI can consume
- Ensure tool stdout/stderr is streamed incrementally
- Keep model “reasoning” to safe high-level status updates only

Exit criteria:

- A client can subscribe to live runtime progress without parsing logs

## Phase 4: Persistence and Recovery

Goal: make runs durable and restart-safe.

- Introduce SQLite-backed persistence behind a clear store interface
- Persist:
  - threads
  - messages
  - runs
  - run state transitions
  - tool calls
  - append-only event log
- Keep persistence behind a store interface so SQLite remains the default implementation, not an architectural assumption
- Normalize previously-running runs to `interrupted` on startup
- Ensure every emitted runtime event is also persisted
- Make persistence useful for debugging and later UI history screens

Exit criteria:

- Runs survive process restarts in a safe, debuggable state
- Historical execution data can be queried later

## Phase 5: Thin CLI Adapter (First Usable Vertical Slice)

Goal: provide a usable command-line vertical slice.

- Build a simple CLI entry point over the runtime
- Accept prompt, workspace path, storage path, and max iterations
- Render live events as the run executes
- Print final answer and terminal errors clearly
- Keep formatting concerns out of domain logic
- Treat the CLI as the first real product surface for the MVP, but not as the long-term center of the architecture

Exit criteria:

- A user can run the agent from terminal and observe the full execution flow

## Phase 6: Real Model Provider Integration

Goal: replace the mock model with a real provider boundary.

- Keep `ModelAdapter` stable
- Add one real provider implementation first
- Define tool schema serialization sent to the model
- Parse structured model responses into typed actions
- Add retry, malformed output handling, and provider error surfaces
- Keep model/provider choice configurable

Exit criteria:

- The runtime can complete realistic tasks using an actual model

## Phase 7: Approvals, Sandboxing, and Safer Execution

Goal: move from “developer MVP” toward a safer local agent.

- Add approval policy abstraction for tool execution
- Add shell approval prompts for dangerous commands
- Add filesystem write approval mode
- Add stricter shell policy hooks
- Prepare for future sandbox profiles
- Record approvals/denials in event log

Exit criteria:

- The system can run in both trusted and guarded modes

## Phase 8: Better Conversation and Run UX

Goal: make the agent feel coherent across multiple interactions.

- Support continuing an existing thread
- Add lightweight system prompt/configuration support
- Improve message formatting for tool outputs
- Add run summaries
- Add thread metadata such as title and updated-at
- Add clear distinction between user, assistant, tool, and system messages

Exit criteria:

- Users can revisit, inspect, and continue prior work cleanly

## Phase 9: Harness and Context Quality

Goal: make the runtime behave more like a serious coding-agent harness instead of a thin tool loop.

- Introduce shared prompt assembly instead of provider-specific prompt building
- Add explicit context preparation and compaction
- Persist context compaction records
- Capture stable workspace snapshot facts per run
- Add rolling working-memory state per run
- Extract tool execution lifecycle into its own boundary
- Make exploration and validation guidance task-type aware
- Improve inspect-before-mutate reliability and changed-file tracking

Exit criteria:

- The runtime has durable harness state instead of relying only on raw transcript replay
- Prompt assembly, context management, and tool execution are clearly separated
- Coding tasks explore and validate more deliberately than a generic tool loop

## Phase 10: SwiftUI App Integration Boundary

Goal: make integration into the macOS app straightforward.

- Keep `AshexCore` UI-agnostic
- Preserve `AsyncStream<RuntimeEvent>` as the main live event boundary
- Add simple query APIs for loading thread, run, message, and event history
- Add runtime control APIs for:
  - start run
  - cancel run
  - continue thread
  - fetch thread
  - fetch run events
- Keep CLI and future UI surfaces as adapters over the same runtime
- Avoid introducing view-driven domain mutations that would force runtime refactors later

Exit criteria:

- A SwiftUI client can consume and control the runtime without domain refactors

## Phase 11: MVP Hardening

Goal: make the MVP reliable enough for regular local use.

- Add focused unit tests for tools, workspace guard, persistence, and loop behavior
- Add integration tests for end-to-end runs
- Add failure-path tests for timeouts, invalid tool calls, and interrupted runs
- Improve structured logging around persistence and process execution
- Audit run state integrity
- Write a short operator/developer guide

Exit criteria:

- The MVP is stable, debuggable, and understandable by another engineer

## What “Small but Serious MVP” Means

A small but serious MVP for Ashex should include:

- Single-agent runtime
- Real or replaceable model integration behind a stable adapter
- Filesystem and shell tools
- Strict workspace-root enforcement
- Typed streaming events
- SQLite persistence
- Restart-safe run recovery
- CLI usage
- Clear runtime/UI boundary
- Basic extension points for future approvals and safer execution

It should not yet include:

- Multi-agent orchestration
- Vector memory or retrieval systems
- Marketplace/plugin ecosystem
- Complex cloud sync
- Large provider matrix
- Autonomous background scheduling
- Full policy engine or sandbox suite

## Suggested Build Order

If we want the fastest path to something convincingly usable, the best order is:

1. Foundation and runtime
2. Tools and workspace safety
3. Streaming
4. Persistence and recovery
5. CLI vertical slice
6. Real model provider
7. Approvals and safer execution
8. Better conversation and run UX
9. Harness and context quality
10. SwiftUI integration boundary
11. Hardening

## Current Status

Already implemented in the repo:

- Foundation/package structure
- Minimal agent loop
- Filesystem tool with read/search/write/move/copy/delete/info operations
- Shell tool
- Git inspection tool
- Typed SwiftPM and Xcode build/test tool
- Shared typed tool-contract model across embedded tools
- Bundled installable tool packs for:
  - SwiftPM
  - iOS/Xcode
  - Python
- Embedded tool-pack scaffold tool for creating reusable custom pack manifests
- Streaming event model
- SQLite persistence
- Restart normalization for interrupted runs
- Thin CLI adapter
- Terminal TUI with:
  - provider/model switching
  - API key entry
  - workspace switching
  - recent workspace switching
  - history browsing
  - side terminal pane
  - approvals
- Real model provider boundary with:
  - mock
  - OpenAI
  - Anthropic
  - Ollama
- Guarded approvals and shell policy config
- Provider secrets moved to local JSON with legacy SQLite credential migration
- Shell command policy can escalate unknown commands into guarded approval flow
- Explicit workspace sandbox modes with protected-path enforcement
- Rule-based shell command policy with allow / prompt / deny behavior
- Global plus project-local policy loading with project precedence
- First-class network policy for shell execution
- Task planning and phase-aware execution
- Inspect-before-mutate enforcement
- Working memory and workspace snapshot persistence
- Context compaction with clipping and dedup of repeated old tool reads
- Task-type-aware exploration and validation guidance
- Workspace-aware exploration strategy with concrete inspect/search/read recommendations
- Validation gating that requires concrete verification before concluding edited runs
- Structured patch-style file editing with diff-native summaries
- Richer working memory with recent findings, completed steps, unresolved items, and better history replay context
- Durable planned change sets, patch objectives, and carry-forward notes for longer coding sessions
- Stalled-step recovery and stronger final summaries for larger tasks
- More managed delegated handoffs with role/goal assignment and carry-forward integration

Most important remaining work:

- deeper automatic exploration and file targeting for bigger coding tasks
- stronger validation execution and check selection beyond the current automatic validation layer
- deeper multi-file patch planning and execution status tracking
- even stronger longer-session memory quality and thread continuation behavior beyond the current carry-forward notes
- deeper secrets, safety, and sandboxing hardening beyond the current local JSON storage and shell-policy enforcement
- richer multi-workspace/session UX beyond the new recent-workspace picker and previews
- richer delegated-agent orchestration beyond the current bounded subtask flow
- bounded subagents later

Likely next highest-value step:

- Production-grade coding-agent behavior refinement on top of the current harness:
  - deeper automatic exploration and file targeting for coding tasks
  - stronger validation execution and check selection
  - richer patch planning and multi-file edit workflows
  - even stronger longer-session memory quality and thread continuation behavior
- stronger multi-agent orchestration beyond the current bounded delegation layer
- deeper safety/sandbox hardening
- more managed subagent assignment / handoff coordination
  - continued session / harness / tool-execution decoupling as the runtime grows

After that:

- SwiftUI integration when the terminal/runtime workflow is stable enough

## Next-Stage Roadmap

The phases above cover the foundation, MVP, harness, and production-shaping work.

The next roadmap is refinement-oriented rather than foundation-oriented. It focuses on:

- deeper exploration and file targeting
- stronger validation execution
- richer multi-file patch planning
- stronger long-session behavior
- more advanced multi-agent orchestration

See [`production-refinement-roadmap.md`](production-refinement-roadmap.md) for the current next-stage plan.

## Active Handoff Phases

These phases capture the non-completed work from the latest handoff plus the Graphify-native knowledge-layer request. Each phase should be validated, committed, and pushed before moving to the next one.

### Handoff Phase A: Preserve Current Diagnostics Baseline

Goal: stabilize and preserve the browser/computer/subagent diagnostics work already present in the worktree.

- Validate `ashex tools list/doctor`.
- Validate `ashex browser doctor/backends`.
- Validate `ashex computer doctor`.
- Validate `ashex subagents list/doctor`.
- Keep the reserved `validate agent-capabilities` namespace from falling through into the TUI.
- Commit the validated baseline before layering more behavior on top.

Exit criteria:

- `swift build` passes.
- Focused diagnostics tests pass.
- CLI diagnostic smoke commands pass.

### Handoff Phase B: Browser Local Validation

Goal: complete browser backend validation with deterministic local fixtures.

- Keep `ashex browser test-local` offline and fixture-backed.
- Allow localhost navigation only for the explicit local test flow.
- Support managed Chrome/CDP startup when configured or discoverable.
- Confirm fetch/eval/screenshot paths work against local fixtures.
- Cover browser process cleanup with focused tests.

Exit criteria:

- Browser CLI tests pass.
- `ashex browser test-local --json` passes when a supported backend is available or fails with clear backend guidance.

### Handoff Phase C: Direct Computer-Use CLI

Goal: expose explicit CLI commands for safe computer-use validation.

- Add `ashex computer screenshot --output <path>`.
- Add `list-windows`, `focus-app`, `click`, `type`, `hotkey`, `scroll`, and `test-local`.
- Use a deterministic mock backend for offline validation.
- Keep real macOS backend failures permission-oriented and actionable.

Exit criteria:

- Computer-use unit tests pass.
- Mock CLI smoke tests pass without requiring GUI permissions.

### Handoff Phase D: Agent Tool Registry And Subagent Commands

Goal: make browser/computer/subagent capability surfaces first-class and testable.

- Keep browser tools registered and passing `tools doctor`.
- Keep the aggregate `computer_use` tool and document any per-action compatibility choice.
- Add `ashex subagents run` and `ashex subagents test-local`.
- Enforce built-in subagent tool allowlists, max steps, and timeouts.
- Return structured run/test results.

Exit criteria:

- Tool registry diagnostics pass.
- Subagent registry and CLI tests pass.

### Handoff Phase E: End-To-End Agent Capability Validation

Goal: replace the placeholder validator with a deterministic offline capability check.

- Implement `ashex validate agent-capabilities [--json]`.
- Add filters for `--browser`, `--computer`, `--subagents`, and `--integration`.
- Check config parsing, tool registry, browser local capability, computer mock capability, subagent mock delegation, safety config, and trace availability.
- Keep integration checks opt-in.

Exit criteria:

- `ashex validate agent-capabilities --json` passes offline.
- Focused validation tests pass.

### Handoff Phase F: Documentation And Final Hardening

Goal: align docs with the implemented commands and finish broad validation.

- Update browser, computer-use, subagent, safety, and validation docs.
- Update the validation audit with completed phases and commands run.
- Remove debug output and check for orphan process risks.
- Run formatter/linter if present.
- Run `swift build` and `swift test`.

Exit criteria:

- Full SwiftPM test suite passes or any environment-specific skips are documented.
- Audit and docs match the shipped CLI.

## Graphify-Native Knowledge Phases

The Graphify prompt adds a new knowledge-layer track. ASHEX should treat Graphify as a first-pass project understanding subsystem while preserving exact file inspection, terminal execution, and validation as the source of truth for edits.

### Graphify Phase 0: Research And Integration Plan

Goal: document Graphify accurately before implementing wrappers.

- Research the official Graphify repo and package behavior.
- Record supported inputs, dependencies, outputs, query/update commands, install guidance, and integration risks in `docs/GRAPHIFY_RESEARCH.md`.
- Note that current upstream full initial graph building is assistant-skill-driven (`/graphify <path>`), while the terminal CLI covers query/path/explain/update/watch/cluster/hook/serve-style support.

Exit criteria:

- `docs/GRAPHIFY_RESEARCH.md` exists.
- This roadmap contains the Graphify phases.

### Graphify Phase 1: Swift Service And CLI Foundation

Goal: add a safe first-class ASHEX wrapper around installed Graphify capabilities.

- Add a dedicated Swift service layer, such as `GraphifyService`, `GraphifyCommandRunner`, `KnowledgeGraphProvider`, and `ProjectGraphContext`.
- Detect the `graphify` executable, Python import availability, version, `graphify-out/graph.json`, `GRAPH_REPORT.md`, and state metadata.
- Add `ashex graphify status [--json]`.
- Add `ashex graphify query`, `path`, `explain`, and `report`.
- Keep missing Graphify and missing graph cases non-fatal with clear next actions.

Exit criteria:

- Graphify service tests cover installed/missing detection, command construction, query/report behavior, and graph metadata parsing.
- CLI help and smoke commands work.

### Graphify Phase 2: Metadata, Rebuild, And Cache Management

Goal: manage graph state without pretending unsupported upstream build operations exist.

- Store ASHEX graph state under `.ashex/graphify/state.json`.
- Add `ashex graphify rebuild` using upstream `graphify update <project>` when a graph exists.
- Add `ashex graphify cluster-only` if useful for report regeneration.
- Add `ashex graphify clean` as an explicit guarded operation.
- For initial `build`, run only safe preparation/status steps and print verified upstream instructions when the full assistant-driven build is required.

Exit criteria:

- State read/write tests pass.
- Rebuild/clean command construction and guardrails are tested.

### Graphify Phase 3: Planner Context Integration

Goal: make ASHEX Graphify-aware for repo-level reasoning.

- Classify architecture, dependency, module behavior, onboarding, and large-refactor prompts as Graphify candidates.
- Query graph context first when `graphify-out/graph.json` exists.
- Normalize results into compact `<project_graph_context>` blocks.
- Feed related files back into exact inspection and validation flows.
- Avoid Graphify for tiny known-file edits.

Exit criteria:

- Planner tests prove Graphify is chosen for architecture questions and skipped for trivial edits.
- Context blocks stay bounded and include related files, relationships, and confidence.

### Graphify Phase 4: Tool And Terminal Reliability Tie-In

Goal: align Graphify with safer tool and terminal execution.

- Ensure tool metadata exposes side effects, network needs, approvals, timeouts, and working-directory behavior.
- Normalize terminal/tool results with success, output/error, exit code, artifacts, and summary.
- Improve command classification for Graphify, build/test/lint, package-manager, network, destructive, and credential-sensitive commands.
- Preserve logs for long terminal output and redact likely secrets.

Exit criteria:

- Terminal classification, timeout, truncation, redaction, failed-command recovery, and working-directory tests pass.

### Graphify Phase 5: Documentation And Flow Tests

Goal: make the Graphify-native workflow observable and maintainable.

- Document Graphify commands, installation guidance, graph state, and planner behavior.
- Add flow tests for architecture question, refactor request, and build failure examples.
- Update release/roadmap docs with completed Graphify scope and known upstream limitations.

Exit criteria:

- Focused Graphify tests pass.
- `swift build` and relevant CLI smoke commands pass.
