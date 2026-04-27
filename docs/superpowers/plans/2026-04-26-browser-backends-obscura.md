# Browser Backends Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add optional, experimental browser automation backends to ASHEX with Obscura support plus Chrome CDP fallback, without breaking existing CLI or agent tool behavior.

**Architecture:** Add a new `AshexCore` browser subsystem that owns config mapping, URL safety policy, process lifecycle, CDP transport, backend selection, and agent-facing browser tools. Keep CLI parsing in `AshexCLI`, wire built-in tools through `RuntimeToolFactory`, and make Obscura entirely optional so ASHEX still builds and runs when the binary is absent.

**Tech Stack:** Swift 6.2, Foundation `Process`, `URLSession`, `URLSessionWebSocketTask`, Swift Testing, existing ASHEX tool/config/runtime abstractions.

---

### Task 1: Add Browser Config And Safety Models

**Files:**
- Create: `Sources/AshexCore/Browser/BrowserTypes.swift`
- Modify: `Sources/AshexCore/UserConfig.swift`
- Test: `Tests/AshexCoreTests/BrowserConfigTests.swift`

- [ ] Write failing tests for browser config defaults, snake/camel key decoding, and security defaults.
- [ ] Run `swift test --filter BrowserConfigTests` and confirm failure is due to missing browser config types.
- [ ] Add typed browser config models plus `AshexUserConfig.browser`.
- [ ] Re-run `swift test --filter BrowserConfigTests` and confirm pass.

### Task 2: Add URL Safety Validation

**Files:**
- Modify: `Sources/AshexCore/Browser/BrowserTypes.swift`
- Create: `Sources/AshexCore/Browser/BrowserSecurity.swift`
- Test: `Tests/AshexCoreTests/BrowserSecurityTests.swift`

- [ ] Write failing tests covering `file://`, `localhost`, private IP, and allowed public HTTPS navigation.
- [ ] Run `swift test --filter BrowserSecurityTests` and confirm the validation failure mode is correct.
- [ ] Implement URL validation and browser-specific errors with clear messages.
- [ ] Re-run `swift test --filter BrowserSecurityTests` and confirm pass.

### Task 3: Add Process And Discovery Utilities

**Files:**
- Create: `Sources/AshexCore/Browser/BrowserProcessSupport.swift`
- Modify: `Sources/AshexCore/ShellExecutionRuntime.swift`
- Test: `Tests/AshexCoreTests/BrowserProcessSupportTests.swift`

- [ ] Write failing tests for binary discovery, help-flag detection, and timeout cleanup behavior.
- [ ] Run `swift test --filter BrowserProcessSupportTests` and confirm failure.
- [ ] Implement reusable process launch, output capture, help probing, free-port selection, and cleanup helpers.
- [ ] Re-run `swift test --filter BrowserProcessSupportTests` and confirm pass.

### Task 4: Add Minimal CDP Client

**Files:**
- Create: `Sources/AshexCore/Browser/CDPClient.swift`
- Test: `Tests/AshexCoreTests/CDPClientTests.swift`

- [ ] Write failing tests for JSON-RPC request/response id matching, timeout handling, and event fan-out.
- [ ] Run `swift test --filter CDPClientTests` and confirm failure.
- [ ] Implement the minimal async CDP client over HTTP + WebSocket.
- [ ] Re-run `swift test --filter CDPClientTests` and confirm pass.

### Task 5: Add Browser Backend Abstractions And Backends

**Files:**
- Create: `Sources/AshexCore/Browser/BrowserBackend.swift`
- Create: `Sources/AshexCore/Browser/ChromeCdpBrowserBackend.swift`
- Create: `Sources/AshexCore/Browser/ObscuraBrowserBackend.swift`
- Create: `Sources/AshexCore/Browser/BrowserManager.swift`
- Test: `Tests/AshexCoreTests/BrowserBackendTests.swift`

- [ ] Write failing tests for backend selection, markdown fallback, and session lifecycle behavior.
- [ ] Run `swift test --filter BrowserBackendTests` and confirm failure.
- [ ] Implement the browser backend protocol, automatic backend selection, Chrome CDP fallback, and Obscura lifecycle with capability probing.
- [ ] Re-run `swift test --filter BrowserBackendTests` and confirm pass.

### Task 6: Add Agent Browser Tools

**Files:**
- Create: `Sources/AshexCore/BrowserTool.swift`
- Modify: `Sources/AshexCore/ToolPacks.swift`
- Test: `Tests/AshexCoreTests/BrowserToolTests.swift`

- [ ] Write failing tests for `browser_fetch`, `browser_extract`, `browser_eval`, and `browser_screenshot` contracts and outputs.
- [ ] Run `swift test --filter BrowserToolTests` and confirm failure.
- [ ] Implement agent-facing browser tools and register them in `RuntimeToolFactory`.
- [ ] Re-run `swift test --filter BrowserToolTests` and confirm pass.

### Task 7: Add CLI Browser Commands

**Files:**
- Create: `Sources/AshexCLI/BrowserCLI.swift`
- Modify: `Sources/AshexCLI/CLIProgram.swift`
- Test: `Tests/AshexCLITests/BrowserCLITests.swift`

- [ ] Write failing CLI parsing tests for `doctor`, `backends`, `fetch`, `eval`, `screenshot`, `serve`, and `benchmark`.
- [ ] Run `swift test --filter BrowserCLITests` and confirm failure.
- [ ] Implement CLI commands and keep help text aligned with existing command style.
- [ ] Re-run `swift test --filter BrowserCLITests` and confirm pass.

### Task 8: Add Config Set Support For Browser Keys

**Files:**
- Create: `Sources/AshexCLI/ConfigCLI.swift`
- Modify: `Sources/AshexCLI/CLIProgram.swift`
- Test: `Tests/AshexCLITests/ConfigCLITests.swift`

- [ ] Write failing tests for `ashex config set browser.backend obscura` and `browser.obscura.path`.
- [ ] Run `swift test --filter ConfigCLITests` and confirm failure.
- [ ] Implement minimal config set support that safely updates `ashex.config.json`.
- [ ] Re-run `swift test --filter ConfigCLITests` and confirm pass.

### Task 9: Add Integration Tests And Fixtures

**Files:**
- Create: `Tests/AshexCoreTests/BrowserIntegrationTests.swift`
- Create: `Tests/Fixtures/browser/`

- [ ] Add env-gated integration tests for local fixture navigation, evaluation, extraction, screenshot, and process cleanup.
- [ ] Keep all integration tests local-only and skipped unless `ASHEX_TEST_OBSCURA=1`.

### Task 10: Add Docs

**Files:**
- Create: `docs/browser-backends.md`
- Modify: `README.md`
- Modify: `docs/usage/configuration.md`

- [ ] Document the browser backend system, Obscura’s experimental status, security defaults, config keys, CLI examples, troubleshooting, and fallback behavior.

### Task 11: Verify End-To-End

**Files:**
- Modify: `Package.swift` only if needed for source organization

- [ ] Run focused unit tests for the new browser files.
- [ ] Run broader `swift test` coverage for existing suites impacted by config/CLI/tool changes.
- [ ] Build the package with `swift build`.
- [ ] Summarize limitations and future follow-ups.
