# Release Prep

Use this file when preparing the next release after the current repository-structure refactor.

## Canonical Release Docs

- [`../../docs/release/production-readiness-checklist.md`](../../docs/release/production-readiness-checklist.md)
- [`../../docs/release/upcoming-release-prep.md`](../../docs/release/upcoming-release-prep.md)

## Release Flow

1. Run the full validation suite with `swift test`.
2. Verify the README and docs links resolve to the new `docs/` structure.
3. Confirm no stale references to the old root-level Markdown paths remain.
4. Summarize the docs and `.codex` reorganization in release notes.
5. Tag or cut the release only after the refactor commit is pushed and green.
