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
- Provider secrets moved to Keychain with legacy SQLite credential migration
- Shell command policy can escalate unknown commands into guarded approval flow
- Task planning and phase-aware execution
- Inspect-before-mutate enforcement
- Working memory and workspace snapshot persistence
- Context compaction with clipping and dedup of repeated old tool reads
- Task-type-aware exploration and validation guidance
- Workspace-aware exploration strategy with concrete inspect/search/read recommendations
- Validation gating that requires concrete verification before concluding edited runs
- Structured patch-style file editing with diff-native summaries
- Richer working memory with recent findings, completed steps, unresolved items, and better history replay context
- Stalled-step recovery and stronger final summaries for larger tasks

Most important remaining work:

- deeper automatic exploration and file targeting for bigger coding tasks
- stronger validation execution and check selection beyond the current gating layer
- richer patch planning and multi-file edit workflows
- even stronger longer-session memory quality and thread continuation behavior
- deeper secrets, safety, and sandboxing hardening beyond the current Keychain storage and shell-policy enforcement
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

See `PRODUCTION_REFINEMENT_ROADMAP.md` for the current next-stage plan.
