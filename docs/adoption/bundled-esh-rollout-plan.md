# Bundled Esh Rollout Plan

Goal: let users install and run `ashex` with local `esh` integration available out of the box, without asking them to separately install `esh`.

## Decisions

- Keep `Ashex` as the agent runtime and UX surface.
- Keep `esh` as the local inference/runtime engine.
- Prefer shipping `esh` alongside `ashex` in the same install artifact rather than embedding `EshCore` directly into `Ashex`.
- Make the bridge capability-aware so MLX and GGUF can both work, even if they do not share the same cache features yet.

## Checklist

- [x] Add a rollout plan in the repo with tracked tasks and `esh` follow-ups.
- [x] Teach `Ashex` to auto-discover a bundled `esh` binary before falling back to `PATH`.
- [x] Switch the `Ashex` bridge to prefer `esh infer` and `esh capabilities`, using cache build/load only when the selected model reports support for it.
- [x] Extend `Ashex` release packaging to optionally bundle a prebuilt `esh` binary into the `ashex` archive.
- [x] Extend local install flow to optionally place `esh` beside `ashex` for developer installs.
- [x] Update Homebrew packaging so bundled `esh` is installed into the same `libexec` layout as `ashex`.
- [ ] Add a release smoke test that verifies `ashex` can resolve bundled `esh` without extra user setup.
- [x] Expose `esh` as a first-class local provider path in `Ashex`, instead of only as an optimization layer on top of `ollama`.
- [x] Add provider/TUI messaging in `Ashex` that clearly distinguishes:
  local bundled `esh` available
  bundled `esh` missing
  bundled `esh` present but runtime/model setup incomplete

## Ashex Work

### Phase 1

- Auto-discover bundled `esh` from the installed `ashex` location.
- Keep existing config and env overrides higher priority than bundled discovery.
- Make packaging scripts able to include `esh` when a prebuilt binary path is supplied.

### Phase 2

- Make the release archive install both binaries together.
- Update Homebrew formula generation to preserve the co-installed layout.
- Add smoke coverage for bundled resolution.

### Phase 3

- Promote this from an optimization seam to a real local-provider surface in `Ashex`.
- Keep compatibility-aware routing so `Ashex` can pick the right `esh` path for MLX vs GGUF.

## Needed In Esh

These changes are still best done in the `esh` repo.

- [x] Add one stable non-interactive inference command for external callers.
  Suggested shape: `esh infer --model <id> --format json`
- [x] Make that inference command work for both MLX and GGUF through the backend registry.
- [x] Add machine-readable capability reporting.
  Suggested shape: `esh capabilities --model <id> --format json`
- [ ] Keep cache build/load as MLX-specific optimization features unless GGUF cache support becomes real.
- [ ] Return structured metadata for automation-friendly callers:
  backend, model id, supports cache import/export, supports tools, supports images, TTFT/tok_s when available.

## Notes

- The current `Ashex` bridge already exists, but it is effectively MLX-oriented because `esh cache build/load` is MLX-only today.
- Bundling `esh` is the simplest path to "works out of the box" without coupling `Ashex` directly to MLX, Python bridge details, or `llama.cpp` packaging internals.
