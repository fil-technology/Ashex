# Upcoming Release Prep

This file tracks the next release once the documentation and repository structure refactor is committed and pushed.

## Scope Of This Release

- move long-form Markdown documentation into `docs/`
- add a curated `.codex/` knowledge area for future Codex sessions
- update README links and documentation map
- preserve architecture-aware instruction discovery after the docs move
- add release packaging and Homebrew tap preparation for one-command installs

## Validation Before Release

- run `swift test`
- verify the README links open the new docs locations
- verify `WorkspaceSnapshotBuilder` still surfaces the moved instruction docs
- sanity-check that no old root-level doc references remain
- run `./scripts/package_source_release.sh <version>` and confirm the source archive lands in `.dist/`
- run `./scripts/package_release.sh <version>` and confirm the binary archive lands in `.dist/`
- run `./scripts/render_homebrew_formula.sh ...` and confirm the generated formula points at a published release asset URL

## Release Notes Draft

- documentation is now organized under `docs/` by roadmap, release, connector/provider, adoption, and research topics
- `.codex/` now provides curated architecture and release guidance for future agent sessions
- README now includes a documentation index and direct links to all major project plans
- release packaging now emits a versioned macOS archive and checksum from this repo
- Homebrew formula generation is now scripted so the tap repo can track tagged releases cleanly

## After Push

- update any external references that pointed at the old root-level Markdown files
- cut the next release from the refactored structure once validation is green
- publish the generated `ashex.rb` formula into `fil-technology/homebrew-tap`
