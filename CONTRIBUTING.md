# Contributing

Thanks for taking a look at Ashex.

## Before Opening A PR

1. Make sure the change is scoped and explained clearly.
2. Run `swift test` from the repository root.
3. Update docs when behavior, commands, or configuration change.
4. Avoid committing local runtime state such as `.ashex/` data or machine-specific config.

## Development Notes

- main code lives in `Sources/AshexCore` and `Sources/AshexCLI`
- roadmap and release material lives under `docs/`
- `.codex/` contains curated architecture notes for future agent sessions

## Pull Request Guidelines

- keep changes focused
- explain user-visible behavior changes in the PR description
- mention any provider- or platform-specific limitations
- include verification notes, especially for daemon, Telegram, or model-adapter changes

## Reporting Issues

When reporting a bug, include:

- what you asked Ashex to do
- active provider and model
- whether the run was CLI, TUI, or Telegram-based
- any relevant log or error output
