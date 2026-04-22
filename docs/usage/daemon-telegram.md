# Daemon And Telegram Guide

Ashex includes a daemon path for long-running background work and Telegram as the first reusable messaging connector.

## Commands

- `daemon run`: start Ashex in the foreground as a long-running process.
- `daemon start`: launch the daemon in the background and write logs under `STORAGE/daemon/daemon.log`.
- `daemon stop`: send `SIGTERM` to the tracked daemon process.
- `daemon status`: show PID and log path when the daemon is running.
- `telegram test`: verify the configured Telegram bot token with `getMe`.
- `cron list`: list persisted cron jobs.
- `cron add --id ID --expr "MIN HOUR DAY MONTH WEEKDAY" --tz "Area/City" --prompt "..."`: add a timezone-aware recurring cron job.
- `cron remove --id ID`: remove a persisted cron job.

## Quick Example

```bash
export ASHEX_TELEGRAM_BOT_TOKEN=123456:bot-token
ashex telegram test
ashex daemon run --workspace /full/path/to/project --provider openai --model gpt-5.4-mini
```

Cron jobs can run through the daemon even when Telegram is disabled:

```bash
ashex cron add \
  --id morning-brief \
  --expr "0 7 * * 1-5" \
  --tz "Asia/Jerusalem" \
  --prompt "Summarize overnight repo updates and list urgent follow-ups."
```

## TUI Setup Path

1. Launch `ashex`.
2. Open `Assistant Setup`.
3. Choose the provider and model you want for daemon runs.
4. Save the provider API key if needed.
5. Enable Telegram, choose an access mode, and save the Telegram bot token.
6. If access gating is enabled, save allowed private chat IDs and optional user IDs.
7. Use `Telegram Test` to verify the bot token.
8. Use `Daemon` to start the background process.

You can also start setup directly:

```bash
ashex onboard
```

## Telegram Execution Modes

- `assistant_only`: denies approval-gated tool actions, keeping Telegram as a read-only assistant entrypoint for normal chat.
- `approval_required`: opens a remote approval inbox inside the Telegram chat and waits for `/approve` or `/deny`.
- `trusted_full_access`: allows Telegram to use the normal runtime tool path; sandbox and shell/network policies still apply.

For owner-controlled bots, `trusted_full_access` enables Telegram-triggered tool use. For shared or public bots, prefer `assistant_only`.

## Access Modes

- `open`: the bot can reply to any private Telegram chat.
- `allowlist_only`: unapproved chats receive a setup reply that includes the sender's chat ID and user ID.

When `allowlist_only` is enabled, unauthorized users receive:

- their Telegram chat ID
- their Telegram user ID
- the exact `Assistant Setup` fields to update
- a reminder to restart the daemon after changing the allowlist

## Runtime Behavior

- Direct-chat prompts such as "How are you?" are routed normally and show a typing indicator while the model runs.
- General requests like summaries, explanations, and code snippets prefer direct-chat routing.
- Project/workspace prompts and explicit command prompts such as `shell: ...` go through the normal runtime intent classifier.
- If the daemon is started without `--workspace`, it uses `~/Ashex/DefaultWorkspace`. Start or restart it with `--workspace /full/path/to/project` when Telegram should operate on a specific repository.
- `/pwd` shows the active daemon workspace root.
- `/workspace` shows workspace command help and the daemon restart command for the current root.
- `/last` inspects the latest persisted run with patch status, validation confidence, remaining work, and subagent audit notes.
- `/ls [path]` lists files from the active daemon workspace without invoking the model.
- `/mkdir path` creates a folder without invoking the model when Telegram execution is `trusted_full_access`.
- `/progress [quiet|normal|verbose]` controls live plan, step, changed-file, and subagent updates in that chat.
- Simple file listing and folder creation requests are handled by deterministic workspace shortcuts where possible, so they do not wait on a local model request.
- `/status`, `/pending`, `/approve`, `/deny [reason]`, and `/stop` are available while a run is active.
- The connector never silently escalates to trusted execution.
- Telegram replies use Telegram HTML parse mode, so bold text and code blocks render without passing raw Markdown through unchanged.

For implementation details and follow-up work, see [Daemon and Telegram MVP notes](../connectors/daemon-telegram-mvp.md).
