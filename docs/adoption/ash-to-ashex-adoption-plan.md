# Ash To Ashex Adoption Plan

This document captures the full transfer plan for bringing the highest-value ideas from Ash into Ashex without turning Ashex into a clone of the Ash CLI product shell.

The goal is agent capability, not feature parity.

Guiding constraints:

- keep Ashex additive and harness-first
- prefer local-first and repo-aware improvements
- prioritize Apple Silicon efficiency only where it materially helps the agent
- avoid pulling in Ash product-shell concerns unless Ashex explicitly decides to own that surface later
- optimize first for a stronger, testable CLI agent, then for production-grade reliability

## Decision Summary

### Adopt Now

- repo-aware ranked retrieval
- surgical read planning
- planning brief injection into prompts
- run-state synthesis using Ashex persistence
- parser-backed Swift symbol extraction, gated to Swift workspaces
- retrieval evaluation harness with durable fixtures

### Adapt Later

- prompt normalization for stronger local-provider consistency and future cache reuse
- backend/runtime protocol split for first-party native local inference
- backend registry and compatibility validation
- install preflight, download verification, and packaged runtime bootstrap, but only if Ashex starts owning model install/runtime bootstrap directly

### Useful Concept But Not Yet

- cache artifact storage
- runtime cache import/export
- reuse-oriented MLX runtime behavior
- TurboQuant and TriAttention-aware flows

### Ignore

- Ash CLI shell structure
- Ash model search, install, inspect, remove, and variant-picking UX
- cache inspection commands and runtime-management commands
- product-oriented local LLM lifecycle surfaces that do not improve agent execution quality
- feature parity with GGUF and MLX as a near-term goal

## What Must Not Be Copied

Do not copy these from Ash into Ashex:

- the Ash CLI or TUI product shell structure
- command-oriented UX for model management
- cache-management command surfaces
- runtime bootstrap assumptions that imply Ashex now owns Python and model packaging by default
- automatic Homebrew-driven install behavior as a default path
- inference-stack-specific optimizations that only matter once Ashex owns first-party MLX or GGUF execution

## Adoption Tracks

### Track A: Adopt Now

These are the highest-value transfers because they directly improve how an agent chooses files, reads less, plans better, and resumes work more coherently.

#### A1. Repo-Aware Ranked Retrieval

Source ideas:

- `ContextQueryEngine.swift`

Why this helps an agent:

- it reduces wasted exploration iterations
- it increases the odds that the first file reads are relevant
- it lets the agent reason from likely code surfaces instead of broad repository scans

Smallest viable Ashex implementation:

- add a lightweight `ContextIndex`
- index file paths, search tokens, imports when cheaply available, file mtimes, project markers, and git-changed files
- rank files by filename, symbol, token, and repo-state relevance
- expose top results to exploration and planning phases

Complexity:

- medium

Dependency risk:

- low for a text-and-path-first implementation

Additive fit:

- very high

#### A2. Surgical Reads

Source ideas:

- `ContextReadService.swift`

Why this helps an agent:

- the agent often needs a small relevant slice, not the whole file
- targeted line ranges keep prompts smaller and tool loops tighter
- it improves inspect-before-mutate quality

Smallest viable Ashex implementation:

- store suggested line ranges with ranked hits
- add symbol-range or text-hit-range recommendations
- teach prompt assembly to surface 1-2 likely reads before the model calls tools

Complexity:

- low to medium

Dependency risk:

- low

Additive fit:

- very high

#### A3. Planning Brief Injection

Source ideas:

- `ContextPlanningService.swift`

Why this helps an agent:

- it turns retrieval results into an actionable brief
- it gives the model a compact "where to look and why" layer
- it improves step selection during exploration and planning

Smallest viable Ashex implementation:

- introduce `ContextPlanningBrief`
- include summary, top ranked files, suggested reads, open questions, and next steps
- inject this brief into prompt assembly during exploration and planning only

Complexity:

- low to medium

Dependency risk:

- low

Additive fit:

- very high

#### A4. Run-State Synthesis

Source ideas:

- `RunStateSynthesizer.swift`
- concept only from `RunStateStore.swift`, not the storage design

Why this helps an agent:

- it gives a distilled summary of what has already been learned
- it improves resumed runs and long sessions
- it reduces over-reliance on raw transcript replay

Smallest viable Ashex implementation:

- synthesize from existing SQLite records
- derive summary, discoveries, open questions, and suggested next steps from working memory, run steps, tool calls, and events
- surface the synthesis in session inspection and prompt preparation

Complexity:

- low

Dependency risk:

- low

Additive fit:

- very high

#### A5. Parser-Backed Swift Symbol Extraction

Source ideas:

- `SymbolExtractor.swift`

Why this helps an agent:

- Swift repos benefit heavily from symbol-level targeting
- it improves bug-fix, refactor, and feature navigation
- it enables better surgical reads and more accurate ranked retrieval

Smallest viable Ashex implementation:

- add an optional Swift symbol indexer
- enable it only for Swift workspaces
- integrate symbol names and ranges into retrieval scoring and read recommendations

Complexity:

- medium

Dependency risk:

- medium because of `SwiftParser` and `SwiftSyntax`

Additive fit:

- high if kept optional and workspace-aware

#### A6. Retrieval Evaluation Harness

Source ideas:

- `ContextEvaluationHarness.swift`
- `context-eval.json`

Why this helps an agent:

- it lets retrieval quality improve based on evidence
- it prevents brittle heuristics from silently regressing
- it gives Ashex a reliable way to compare ranking changes

Smallest viable Ashex implementation:

- add test fixtures describing query-to-expected-file mappings
- measure top-1, top-3, and MRR
- run this in unit or integration tests

Complexity:

- low

Dependency risk:

- low

Additive fit:

- very high

### Track B: Adapt Later

These are good ideas, but they should come after the repo-intelligence work is proven useful.

#### B1. Prompt Normalization

Source ideas:

- `PromptSessionNormalizer.swift`

Reason to defer:

- useful for stable caching and local-provider consistency
- not the highest-leverage improvement compared with repo targeting and planning quality

Adaptation direction:

- normalize assembled prompts before local-provider submission
- treat it as a shared prompt hygiene layer, not a product feature

#### B2. Backend Runtime Boundary

Source ideas:

- `BackendRuntime.swift`
- `InferenceBackendRegistry.swift`
- `MLXBackend.swift`
- `LlamaCppBackend.swift`

Reason to defer:

- valuable only if Ashex moves beyond Ollama and starts owning first-party local inference backends

Adaptation direction:

- split provider adapters from native local runtimes
- keep model provider logic and local runtime execution separate

#### B3. Compatibility Validation

Source ideas:

- MLX and GGUF compatibility checks in backend code

Reason to defer:

- only relevant once Ashex imports runtime artifacts or manages backend-specific installs

Adaptation direction:

- validate backend-model-runtime compatibility before first-party local execution

#### B4. Install Preflight And Bootstrap

Source ideas:

- `ModelInstallPreflightService.swift`
- `HuggingFaceModelDownloader.swift`
- `PackagedRuntimeBootstrap.swift`

Reason to defer:

- strong hardening patterns, but they solve a runtime ownership problem Ashex does not yet have

Adaptation direction:

- reuse memory and disk preflight patterns if Ashex adds model install/bootstrap
- keep them behind an explicit local-runtime feature gate

### Track C: Useful Concepts But Not Yet

These should remain on the shelf until Ashex clearly owns native local inference.

#### C1. Cache Artifacts

- artifact persistence
- snapshot codecs
- import/export of runtime state

#### C2. MLX Reuse-Oriented Runtime Behavior

- prepare-once and reuse flows
- state-file-backed runtime reuse

#### C3. TurboQuant And TriAttention Integration

- highly specific to Ash's local MLX inference stack
- not justified for Ashex before a native runtime exists

## Concrete Delivery Phases

This section lists the concrete phases needed to get Ashex from its current state to a testable CLI upgrade and then toward production-ready adoption of the right Ash ideas.

### Phase 1: Retrieval Foundation

Goal:

- make Ashex aware of likely relevant files before the model starts broad exploration

Scope:

- add `ContextIndex` models
- add index builder for paths, tokens, basic repo facts, and changed files
- persist or cache the index per workspace as appropriate
- add `ContextQueryEngine`

Exit criteria:

- Ashex can rank likely relevant files for a task
- ranking can be exercised in tests

Target outcome:

- testable CLI upgrade

### Phase 2: Planning Briefs And Surgical Read Recommendations

Goal:

- feed ranked retrieval back into the agent loop in a compact, useful form

Scope:

- add `ContextPlanningBrief`
- add surgical read recommendations with line ranges
- inject planning brief data into prompt assembly during exploration and planning
- expose brief data through working memory and session inspection

Exit criteria:

- exploration prompts contain grounded repo-aware guidance
- the model is nudged toward the right first reads

Target outcome:

- stronger and more testable CLI exploration behavior

### Phase 3: Swift Symbol Intelligence

Goal:

- improve retrieval and targeting for Swift-heavy repos

Scope:

- add optional Swift parser-backed symbol extraction
- record symbol names, containers, and ranges
- feed symbol matches into retrieval ranking and read suggestions

Exit criteria:

- Swift repos show better symbol-level file targeting than text-only matching

Target outcome:

- materially improved CLI behavior on Swift projects

### Phase 4: Run Synthesis And Resume Quality

Goal:

- make resumed or long sessions stay coherent without replaying raw history

Scope:

- synthesize discoveries, decisions, open questions, and next steps from existing Ashex persistence
- surface synthesis in prompt prep and session inspection
- connect synthesis to compaction and working memory summaries

Exit criteria:

- resumed runs start with a distilled state layer
- long sessions degrade less sharply

Target outcome:

- testable long-session CLI upgrade

### Phase 5: Retrieval Evaluation Harness

Goal:

- prevent regressions and improve retrieval intentionally

Scope:

- add evaluation fixtures
- add ranking metrics
- add tests for representative Ashex queries and expected files

Exit criteria:

- retrieval changes can be evaluated numerically
- fixture updates are straightforward

Target outcome:

- reliable testable CLI upgrade path

### Phase 6: Prompt Hygiene And Local Provider Stability

Goal:

- make prompt assembly more stable across providers and future local runtimes

Scope:

- add normalization for prepared prompts
- reduce whitespace and formatting variance
- ensure compaction, planning briefs, and working memory render consistently

Exit criteria:

- prompt output is deterministic enough for better testing and future caching

Target outcome:

- production-shaping CLI refinement

### Phase 7: Native Runtime Boundary Preparation

Goal:

- prepare Ashex to support first-party local inference later without refactoring the harness

Scope:

- define native runtime interfaces separate from current remote-provider adapters
- sketch backend registry boundaries
- decide where compatibility checks and runtime capabilities belong

Exit criteria:

- Ashex has a clean seam for MLX or GGUF later
- no immediate product-shell work is required

Target outcome:

- architectural readiness, not user-facing parity

### Phase 8: First-Party Local Runtime Experiments

Goal:

- evaluate whether native MLX or GGUF ownership is worth it for Ashex

Scope:

- prototype one local runtime path
- validate Apple Silicon efficiency benefits
- measure whether cache reuse materially improves agent throughput or latency

Exit criteria:

- clear evidence to continue or defer first-party runtime ownership

Target outcome:

- strategic decision point, not guaranteed product work

### Phase 9: Runtime Hardening If Ashex Owns Local Inference

Goal:

- make local runtime ownership safe and supportable

Scope:

- install preflight
- compatibility validation
- download verification
- packaged bootstrap
- smoke validation

Exit criteria:

- runtime install and startup are robust enough for regular local use

Target outcome:

- production-ready local-runtime path, only if Phase 8 justifies it

## Production-Ready CLI Upgrade Sequence

If the immediate goal is a stronger, testable CLI and not a native-local-runtime product, the recommended order is:

1. Phase 1: Retrieval foundation
2. Phase 2: Planning briefs and surgical reads
3. Phase 5: Retrieval evaluation harness
4. Phase 4: Run synthesis and resume quality
5. Phase 3: Swift symbol intelligence
6. Phase 6: Prompt hygiene and local provider stability

That sequence gives Ashex the highest-value improvements without dragging in unnecessary runtime ownership complexity.

## Minimum Testable Upgrade Milestone

Ashex should be considered to have reached a meaningful testable upgrade when all of the following are true:

- retrieval can rank likely files for representative tasks
- planning prompts can include a compact repo-aware brief
- surgical reads are suggested or surfaced before mutation
- retrieval quality is measured in tests with durable fixtures
- resumed runs expose synthesized "what we know so far" state

## Minimum Production-Ready Upgrade Milestone

For the repo-intelligence track, production-ready means:

- retrieval is exercised by automated tests
- ranking regressions are detectable
- planning briefs do not bloat prompt assembly excessively
- Swift symbol indexing degrades gracefully when unavailable
- run synthesis is robust across interrupted and resumed runs
- CLI behavior remains additive and does not become a clone of Ash's command shell

For the native-runtime track, production-ready should only be claimed if all of the following are true:

- preflight checks are in place
- download and artifact verification are in place
- compatibility validation is enforced
- bootstrap and smoke validation are reliable on Apple Silicon
- the native path materially improves agent effectiveness, not just architecture purity
