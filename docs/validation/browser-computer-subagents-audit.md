# Browser, Computer Use, And Subagent Validation Audit

Date: 2026-05-01
Workspace: `/Users/sviatoslavfil/Development/Fil.Technology/Codex-based/Agents/Eshex/Source`

This file records the Phase 0 audit for hardening ASHEX browser automation, computer-use automation, sub-agent delegation, diagnostics, tests, and developer documentation.

## Phase 0 Scope

No implementation changes were made before this audit was completed. The only Phase 0 repository change is this audit record.

## Repository Shape

- Swift Package Manager project using `swift-tools-version: 6.2`, Swift language mode v6, macOS 13 minimum.
- Products:
  - `AshexCore` library
  - `AshexComputerUse` library
  - `ashex` executable through `AshexCLI`
- Test targets:
  - `AshexCoreTests`
  - `AshexComputerUseTests`
  - `AshexCLITests`
- Primary source roots:
  - `Sources/AshexCore`
  - `Sources/AshexCLI`
  - `Sources/AshexComputerUse`
- Important docs inspected:
  - `README.md`
  - `docs/AGENTS.md`
  - `docs/SOUL.md`
  - `docs/architecture/runtime-and-tools.md`
  - `docs/AGENT_ARCHITECTURE.md`
  - `docs/COMMAND_EXECUTION.md`
  - `docs/SAFETY.md`
  - `docs/browser-backends.md`
  - `docs/SUBAGENTS.md`
  - `docs/roadmap/implementation-phases.md`
  - `docs/roadmap/deep-agent-implementation-tracker.md`

## Worktree State

The repository had a substantial dirty worktree before this audit began. Existing modified and untracked files include CLI, runtime, computer-use, agent-memory, subagent-workspace, and many test/doc files. Treat this as user work. Future phases must avoid reverting or overwriting unrelated existing changes.

Observed pre-audit dirty state included:

- Modified files such as `Sources/AshexCLI/CLIProgram.swift`, `Sources/AshexCLI/ExecCLI.swift`, `Sources/AshexCLI/TUIApp.swift`, `Sources/AshexComputerUse/*`, `Sources/AshexCore/AgentRuntime.swift`, and several tests.
- Untracked files such as `Sources/AshexCLI/AgentOpsCLI.swift`, `Sources/AshexComputerUse/ComputerUseTool.swift`, multiple new `Sources/AshexCore/Agent*` files, multiple new tests, and many docs under `docs/`.

## Build And Test Status

Commands run:

- `swift build`
  - Result: pass
  - Debug build completed successfully.
- `swift test`
  - Result: pass
  - Swift Testing reported 317 tests in 5 suites passed.

Additional executable probes:

- `swift run ashex doctor --workspace <repo>`
  - Result: pass
  - Reports workspace, storage, config, context files, skills, MCP servers, KB missing sources, and SQLite store.
- `swift run ashex browser doctor --workspace <repo>`
  - Result: pass
  - Configured backend: `chrome-cdp`
  - Obscura: not found
  - CDP endpoint: `http://127.0.0.1:9222`
  - CDP reachable: no
- `swift run ashex browser backends --workspace <repo>`
  - Result: pass
  - `chrome-cdp` unavailable because no CDP endpoint is reachable.
- `swift run ashex computer-use doctor --workspace <repo>`
  - Result: pass
  - `computer_use.enabled` is true in the workspace config.
  - Native macOS fallback selected because `.ashex/background-computer-use.json` is missing.
  - Accessibility and Screen Recording permissions are granted on this machine.
  - Backend status: running.
- `swift run ashex rpc list-tools --workspace <repo>`
  - Result: pass
  - Shows registered runtime tools including browser tools and the aggregate `computer_use` tool.
- `swift run ashex browser fetch http://127.0.0.1:1 --timeout 1 --workspace <repo>`
  - Result: expected failure
  - Localhost navigation is blocked by default with a clear security error.

Command probes for missing top-level namespaces:

- `swift run ashex subagents list ...`
- `swift run ashex tools list ...`
- `swift run ashex validate agent-capabilities ...`

These fell through into interactive TUI startup instead of returning an unknown-command error. The spawned probe processes were killed after discovery. This is a developer UX issue: unknown top-level namespaces can hang non-interactive validation probes.

## Current Feature Inventory

### CLI And Runtime Entrypoints

Existing:

- CLI entrypoint: `Sources/AshexCLI/AppMain.swift` and `Sources/AshexCLI/CLIProgram.swift`.
- One-shot prompt and TUI behavior in `CLIProgram`.
- Non-interactive agent execution in `Sources/AshexCLI/ExecCLI.swift`.
- Diagnostics and agent ops commands in `Sources/AshexCLI/AgentOpsCLI.swift`.
- Browser commands in `Sources/AshexCLI/BrowserCLI.swift`.
- Computer-use prototype and doctor commands in `Sources/AshexCLI/ComputerUseCLI.swift`.
- Runtime construction in `CLIConfiguration.makeRuntime(...)`.
- Tool construction in `RuntimeToolFactory.makeTools(...)` plus CLI-level conditional computer-use registration.

Missing or incomplete:

- No `ashex tools list`.
- No `ashex tools doctor`.
- No `ashex validate agent-capabilities`.
- No `ashex subagents ...` CLI implementation.
- No `ashex computer ...` alias; current namespace is `computer-use`.
- Unknown top-level namespaces can start the TUI instead of failing fast.
- JSON output is absent for `ashex doctor`, `browser doctor`, `browser backends`, and `computer-use doctor`.

### Tool Registry

Existing:

- Typed `Tool`, `ToolContract`, `ToolOperationContract`, `ToolArgumentContract`, and `ToolRegistry`.
- Provider schema generation via `ToolSpec`.
- Runtime tools include filesystem, git, GitHub repo, build, shell, audio, browser tools, agent knowledge, MCP bridge, toolpack scaffold, and installed tool packs.
- `ComputerUseTool` is registered only when `computer_use.enabled` is true.
- `rpc list-tools` provides a developer-visible list of registered tools.

Missing or incomplete:

- `ToolRegistry` currently collapses duplicate names with `Dictionary(uniqueKeysWithValues:)`; duplicates trap instead of producing a diagnostic.
- No first-class tool registry diagnostics for duplicate names, missing handlers, weak descriptions, missing operation contracts, or safety metadata gaps.
- No dedicated `tools list --json` or `tools doctor --json`.
- Browser tools are separate stable names, but computer-use is a single aggregate `computer_use` tool with operation names rather than the requested stable per-action names such as `computer_click` and `computer_screenshot`.

### Browser Automation

Existing:

- Browser config models:
  - `BrowserConfigSection`
  - `BrowserConfig`
  - `BrowserObscuraConfig`
  - `BrowserCDPConfig`
  - `BrowserSecurityConfig`
- Security defaults:
  - file URLs blocked
  - localhost blocked
  - private networks blocked
- URL normalization and validation tests exist.
- Browser backend protocol exists in `Sources/AshexCore/Browser/BrowserBackend.swift`.
- Backends:
  - `ChromeCdpBrowserBackend`
  - `ObscuraBrowserBackend`
- CDP client exists with JSON-RPC request/response matching and WebSocket event waiters.
- Browser manager supports:
  - doctor
  - available backends
  - fetch
  - evaluate
  - screenshot
  - benchmark
  - start session
- Agent tools exist:
  - `browser_fetch`
  - `browser_extract`
  - `browser_eval`
  - `browser_screenshot`
- CLI commands exist:
  - `ashex browser doctor`
  - `ashex browser backends`
  - `ashex browser fetch`
  - `ashex browser eval`
  - `ashex browser screenshot`
  - `ashex browser serve`
  - `ashex browser benchmark`
- Unit tests cover browser config, URL safety, process support, CLI help, tool contracts, and runtime preference for browser tools.

Missing or incomplete:

- `chrome-cdp` only connects to an already running CDP endpoint. It does not launch Chrome/Chromium as a fallback despite Google Chrome being installed at `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`.
- No browser local test server or fixture pages are present.
- No `ashex browser test-local`.
- No local integration tests behind `ASHEX_TEST_BROWSER=1`.
- No `ASHEX_TEST_OBSCURA=1` integration path observed.
- `browser doctor` does not report Chrome executable discovery, Playwright availability, URL safety settings, timeout settings, or JSON output.
- `browser backends` output is not JSON-capable.
- Actual local navigation is currently blocked by default, as expected, but there is no safe `test-local` path that temporarily opts into local test fixtures.
- Browser fetch/eval/screenshot cannot work on this machine without starting an external CDP server or configuring Obscura.
- Process cleanup exists for managed browser processes, but Chrome CDP has no managed process because it only connects to external CDP.

### Computer Use / GUI Automation

Existing:

- Separate `AshexComputerUse` target.
- Config:
  - `computer_use.enabled`
  - `computer_use.backend_manifest_path`
  - `computer_use.safety`
- Provider abstraction exists as `ComputerUseProvider`.
- Providers:
  - `NativeMacOSComputerUseProvider`
  - `ManifestBackedComputerUseProvider`
- Native macOS backend supports:
  - permission status
  - backend status
  - list windows
  - accessibility state
  - screenshots
  - element click
  - coordinate click
  - move mouse
  - drag
  - type text
  - press keys
  - scroll
  - focus app
  - open app
  - open URL
  - wait
- Permission detection exists for Accessibility and Screen Recording.
- Safety policy exists with strict/normal/dev modes.
- Agent-facing `ComputerUseTool` exists as an aggregate tool named `computer_use`.
- CLI doctor exists as `ashex computer-use doctor`.
- CLI prototype loop exists as `ashex computer-use prototype`.
- Unit tests cover command parsing, safety policy, observation building, and tool behavior with recording providers.

Missing or incomplete:

- No requested `ashex computer ...` namespace.
- No direct CLI commands for:
  - `computer screenshot --output`
  - `computer list-windows`
  - `computer focus-app`
  - `computer click`
  - `computer type`
  - `computer hotkey`
  - `computer scroll`
  - `computer test-local`
- No JSON output for computer doctor.
- No explicit ComputerUseBackend protocol matching the requested shape; current `ComputerUseProvider` is close but broader and provider-oriented.
- No first-class mock backend in production code for validation commands. Tests define recording providers locally.
- Doctor does not report AppleScript availability, CGEvent availability, OCR/vision status, Input Monitoring, Automation permission, or tool registration status.
- Tool registry exposes one aggregate `computer_use` tool, not stable per-action tool names.

### Sub-Agents / Multi-Agent Delegation

Existing:

- Runtime-level bounded delegation exists in `AgentRuntime`.
- `DelegationStrategy` creates phase-specific delegation briefs and parallel work items for exploration/validation.
- `executeSubagentLoop` uses isolated local messages, bounded iterations, cancellation checks, model routing by purpose, filtered available tools, and handoff parsing.
- Tool allowlist filtering exists for parallel read-only lanes.
- Workspace leases exist via `SubagentWorkspaceManager`.
- Lease modes:
  - `shared_read_only`
  - `copied_writable`
- Runtime events exist:
  - `subagentAssigned`
  - `subagentStarted`
  - `subagentHandoff`
  - `subagentFinished`
- TUI and CLI render subagent events.
- Tests cover bounded delegation, parallel exploration subagents, and subagent workspace lease behavior.

Missing or incomplete:

- No public `SubAgentDefinition` or `SubAgentRunner` abstraction.
- No named sub-agent registry with roles like `researcher`, `coder`, `reviewer`, or `computer-operator`.
- No project/user sub-agent config.
- No `ashex subagents doctor`.
- No `ashex subagents list`.
- No `ashex subagents run <agent-name> --task ...`.
- No `ashex subagents test-local`.
- No explicit max depth setting beyond bounded runtime step loops.
- No sub-agent specific timeout config or CLI enforcement.
- No tool allowlist tests for a named sub-agent registry because that registry does not exist yet.
- `docs/SUBAGENTS.md` describes desired commands but says they are not active.

### Logging And Diagnostics

Existing:

- Runtime events persist to SQLite.
- Tool calls are persisted.
- Session inspector summarizes runs and subagent audit trails.
- Daemon logging exists.
- `ashex doctor` exists for context/skills/MCP/KB/SQLite.
- Browser and computer-use doctor commands exist.

Missing or incomplete:

- Diagnostics are not unified.
- JSON diagnostics are mostly absent.
- No end-to-end validation command.
- No tool registry doctor.
- No browser local validation scenario.
- No computer-use mock validation scenario.
- No sub-agent mock delegation validation command.

### Safety And Security Controls

Existing:

- Workspace guard and protected paths.
- Shell/network policy assessment.
- Approval policy path.
- Tool operation metadata for mutating and network-requiring operations.
- Browser URL safety defaults.
- Computer-use safety policy and approval metadata.
- Computer-use permissions are checked before tool execution.
- Subagent delegated scopes can filter tools.

Missing or incomplete:

- Per-action computer-use tools are not individually exposed with separate safety metadata.
- Subagent named roles and allowlists are not centrally configurable or inspectable.
- Browser diagnostics do not summarize effective safety config.
- Unknown command fallthrough can create surprising TUI sessions in automation contexts.

## What Exists

- Healthy SwiftPM package with passing build and test suite.
- Browser backend architecture, CDP client, Obscura backend, browser CLI, browser tools, and docs.
- Computer-use target with native macOS backend, permission checks, safety policy, aggregate agent tool, prototype loop, doctor command, and tests.
- Runtime-level subagent delegation, parallel read-only lanes, subagent events, leases, and tests.
- General `ashex doctor` and `rpc list-tools`.

## What Is Missing

- Unified diagnostics and validation commands:
  - `ashex tools list`
  - `ashex tools doctor`
  - `ashex browser doctor --json`
  - `ashex computer doctor`
  - `ashex computer doctor --json`
  - `ashex subagents doctor`
  - `ashex validate agent-capabilities`
- Browser local test server, local fixture pages, and integration tests.
- Managed Chrome/CDP launch fallback.
- Direct computer-use CLI commands beyond doctor/prototype.
- Computer-use mock backend available to validation commands.
- Per-action computer-use agent tools.
- Named sub-agent registry, config, CLI, and mock runner.
- End-to-end validation report.
- Docs for computer use and subagents that match actual CLI behavior.

## What Is Broken Or Risky

- Missing top-level namespaces fall through to the interactive TUI and can hang automation probes.
- Browser docs imply a Chrome/CDP fallback, but current `chrome-cdp` requires an already reachable endpoint.
- Browser CLI cannot currently prove local navigation/eval/screenshot without an external CDP server or Obscura.
- `docs/SUBAGENTS.md` advertises commands as desired but not active.
- `computer-use doctor` exists, while the requested and more ergonomic namespace is `computer`.
- `ToolRegistry` cannot diagnose duplicate tool names because construction would trap first.

## What Is Unclear

- Whether ASHEX should keep `computer_use` as an aggregate tool for model compatibility while adding per-action aliases, or migrate agent prompting to per-action tools.
- Whether managed Chrome launch should live inside `ChromeCdpBrowserBackend` or a separate `ManagedChromeCdpBrowserBackend`.
- How much of sub-agent role execution should reuse `AgentRuntime` versus a smaller mockable `SubAgentRunner`.
- Whether `ashex browser serve` should hold a managed session with explicit cleanup signals or remain a developer-only helper.

## Proposed Implementation Plan

### Phase 1: Diagnostics And Command UX

Acceptance criteria:

- `ashex tools list [--json]` works.
- `ashex tools doctor [--json]` works.
- `ashex browser doctor [--json]` and `ashex browser backends [--json]` work.
- `ashex computer doctor [--json]` works as an alias for `computer-use doctor`.
- `ashex subagents doctor [--json]` and `ashex subagents list [--json]` work with the current runtime/lease state.
- Unknown reserved namespaces fail fast instead of launching the TUI.

Implementation notes:

- Add a lightweight diagnostics layer in `AshexCore` for tool registry validation and structured reports.
- Extend existing CLI files where possible instead of adding duplicate paths.
- Keep `computer-use` commands for backward compatibility and add `computer` as an alias.
- Avoid changing the runtime loop in this phase.

### Phase 2: Browser Backend Validation And Repair

Acceptance criteria:

- `ashex browser test-local` runs a local fixture scenario without public internet.
- `ashex browser fetch/eval/screenshot` work against the local fixture when local navigation is explicitly allowed by the command.
- `chrome-cdp` can either connect to an existing endpoint or launch a managed local Chrome process bound to `127.0.0.1`.
- Screenshots write PNG files.
- Browser process cleanup is covered by tests.

Implementation notes:

- Add a local test server helper and fixture pages under tests.
- Add managed Chrome executable discovery for `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`, PATH candidates, and configured paths.
- Keep Obscura optional and experimental.
- Gate real browser integration tests behind `ASHEX_TEST_BROWSER=1`.

### Phase 3: Computer Use Validation And Direct CLI

Acceptance criteria:

- `ashex computer screenshot --output <path>` works or fails gracefully with permission guidance.
- `ashex computer list-windows`, `focus-app`, `click`, `type`, `hotkey`, `scroll`, and `test-local` exist.
- A mock backend supports safe deterministic validation.
- Real macOS backend failures explain missing permissions.

Implementation notes:

- Reuse `ComputerUseProvider` rather than inventing a second backend layer unless a small adapter improves clarity.
- Add production `MockComputerUseProvider` for tests and validation.
- Keep all GUI-mutating commands explicit and logged.

### Phase 4: Agent Tool Registry Integration

Acceptance criteria:

- Browser tools remain registered and pass `tools doctor`.
- Computer-use per-action tools exist or aggregate-tool compatibility is clearly documented and tested.
- Unavailable backends return structured errors.
- Tool schemas include useful descriptions, required arguments, and safety metadata.

Implementation notes:

- Prefer adding per-action wrappers over removing the existing `computer_use` aggregate tool.
- Add focused tests for tool schema validation and handler execution.

### Phase 5: Named Sub-Agent Registry And CLI

Acceptance criteria:

- `ashex subagents doctor`, `list`, `run`, and `test-local` work.
- Built-in definitions exist for researcher, coder, reviewer, and computer-operator.
- Tool allowlists are enforced.
- Max steps and timeouts are enforced.
- Sub-agent runs return structured results and logs/traces.

Implementation notes:

- Start with a small `SubAgentDefinition` and mockable `SubAgentRunner`.
- Reuse existing runtime events and workspace leases.
- Do not add recursive autonomous spawning beyond bounded explicit delegation.

### Phase 6: End-To-End Validation Command

Acceptance criteria:

- `ashex validate agent-capabilities [--json]` exists.
- It checks config parse, tool registry, browser availability/local test, computer-use mock test, sub-agent mock delegation, safety config, and traces.
- `--browser`, `--computer`, `--subagents`, and `--integration` filters work.

Implementation notes:

- Make the default validation deterministic and offline.
- Put real browser/computer integration behind explicit flags/env vars.

### Phase 7: Documentation And Developer UX

Acceptance criteria:

- `docs/browser-backends.md` matches actual browser behavior.
- `docs/computer-use.md` exists and documents permissions, commands, safety, mock backend, and troubleshooting.
- `docs/subagents.md` exists or `docs/SUBAGENTS.md` is updated to match actual commands.
- README gets only a short mention and links.
- This audit file is updated with completed phases and test status.

### Phase 8: Final Hardening

Acceptance criteria:

- Formatter/linter runs if available.
- `swift build` passes.
- `swift test` passes.
- `ashex validate agent-capabilities --json` passes for offline checks.
- Git diff is reviewed.
- No debug prints or orphan child processes remain.

## Phase 1 Progress

Completed in Phase 1:

- Added core tool-registry diagnostics with duplicate-name detection and contract checks.
- Changed `ToolRegistry` construction so duplicate names are captured diagnostically instead of trapping immediately.
- Added `ashex tools list [--json]`.
- Added `ashex tools doctor [--json]`.
- Added JSON output for `ashex browser doctor --json`.
- Added JSON output for `ashex browser backends --json`.
- Added `ashex computer doctor` as an alias for `ashex computer-use doctor`.
- Added JSON output for `ashex computer doctor --json` and `ashex computer-use doctor --json`.
- Added built-in sub-agent definitions for `researcher`, `coder`, `reviewer`, and `computer-operator`.
- Added `ashex subagents list [--json]`.
- Added `ashex subagents doctor [--json]`.
- Added a placeholder `ashex validate agent-capabilities` handler so the reserved namespace no longer falls through into the TUI. The real validation command remains Phase 6 work.

Phase 1 validation commands run:

- `swift test --filter ToolRegistryDiagnosticsTests`
- `swift test --filter SubAgentRegistryTests`
- `swift test --filter BrowserCLITests`
- `swift run ashex tools list --workspace <repo>`
- `swift run ashex tools doctor --workspace <repo>`
- `swift run ashex tools doctor --json --workspace <repo>`
- `swift run ashex browser doctor --json --workspace <repo>`
- `swift run ashex browser backends --json --workspace <repo>`
- `swift run ashex computer doctor --json --workspace <repo>`
- `swift run ashex computer-use doctor --json --workspace <repo>`
- `swift run ashex subagents list --json --workspace <repo>`
- `swift run ashex subagents doctor --json --workspace <repo>`

Observed Phase 1 status:

- Tool registry diagnostics status: `pass`, 17 tools, no duplicate names.
- Browser diagnostics correctly report Obscura missing and CDP unavailable at `http://127.0.0.1:9222`.
- Computer-use diagnostics report native macOS fallback running with Accessibility and Screen Recording granted on this machine.
- Sub-agent diagnostics report built-in definitions and pass with current tool availability.
- A parallel probe caused one transient `database is locked` error when two diagnostics tried to initialize the same SQLite store at the same time. The same `tools list` command passed when rerun alone. This is a remaining diagnostic robustness issue to consider during final hardening.

Remaining after Phase 1:

- `ashex validate agent-capabilities` is only a reserved placeholder.
- Browser local test and managed Chrome launch are still missing.
- Direct computer-use commands are still missing.
- Per-action computer-use tools are still missing.
- Named sub-agent `run` and mock delegation are still missing.
