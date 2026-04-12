# Daemon + Telegram MVP

## What Was Added

- A daemon-oriented connector architecture in `AshexCore`:
  - `Connector`
  - `ConnectorRegistry`
  - `ConversationRouter`
  - `ConnectorConversationMappingStore`
  - `RunDispatcher`
  - `DaemonSupervisor`
- Runtime support for resuming an existing persisted thread by `threadID`
- Telegram Bot API polling connector with:
  - private-chat text handling
  - `/start`
  - `/help`
  - `/reset`
  - persisted `update_id` deduplication
  - outbound chunking for long text replies
- CLI commands for:
  - `ash daemon run`
  - `ash daemon start`
  - `ash daemon stop`
  - `ash daemon status`
  - `ash telegram test`
- Config additions for daemon, Telegram, and logging settings

## Architecture Decisions

- Persistence reuse over parallel storage:
  - connector conversation mappings and Telegram polling state are stored in the existing SQLite `settings` table
  - runs, messages, thread history, and runtime events continue to use the existing persistence model
- Connector isolation over runtime rewrites:
  - the runtime remains the execution engine
  - connectors only normalize inbound events and deliver outbound text
- Explicit safety boundary for remote entrypoints:
  - `assistant_only` denies approval-gated tool actions
  - `approval_required` is represented explicitly but still blocks execution until a future approval transport exists
- Foreground-first daemon design:
  - `daemon run` is the primary robust flow
  - background start and stop are thin wrappers around the same process path

## Intentionally Deferred

- Non-Telegram connectors such as Discord, Slack, Email, or WhatsApp
- Group chat semantics and richer participant models
- Webhook delivery
- Streaming partial replies back to Telegram
- Media and image pipelines
- Remote approval inbox and approval handoff UX
- Run reattachment or live recovery of in-flight work after restart

## Recommended Next Steps

1. Move processed Telegram update tracking from per-update settings rows into a compact connector state record with pruning.
2. Add a daemon inbox for `approval_required` actions so Telegram can request work without becoming a hidden remote shell.
3. Introduce a small `ConnectorEventAuditRecord` if connector-specific observability needs to go beyond runtime messages and logs.
4. Add connector-level serialization or queueing guarantees per mapped conversation if multi-message bursts become common.
5. Add Discord or Slack by implementing only the connector boundary, not by modifying the runtime path.
