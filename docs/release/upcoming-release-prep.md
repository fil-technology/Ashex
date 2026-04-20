# Upcoming Release Prep

This file tracks the next release once the documentation and repository structure refactor is committed and pushed.

## Scope Of This Release

- move long-form Markdown documentation into `docs/`
- add a curated `.codex/` knowledge area for future Codex sessions
- update README links and documentation map
- preserve architecture-aware instruction discovery after the docs move

## Validation Before Release

- run `swift test`
- verify the README links open the new docs locations
- verify `WorkspaceSnapshotBuilder` still surfaces the moved instruction docs
- sanity-check that no old root-level doc references remain

## Release Notes Draft

- documentation is now organized under `docs/` by roadmap, release, connector/provider, adoption, and research topics
- `.codex/` now provides curated architecture and release guidance for future agent sessions
- README now includes a documentation index and direct links to all major project plans

## After Push

- update any external references that pointed at the old root-level Markdown files
- cut the next release from the refactored structure once validation is green
