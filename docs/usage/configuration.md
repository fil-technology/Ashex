# Configuration And Safety Guide

Ashex reads project config first, then optional global config. Project settings override global settings key-by-key.

## Config Locations

- Project config: `WORKSPACE/ashex.config.json`
- Global config: `~/.config/ashex/ashex.config.json`
- Persistence directory: `WORKSPACE/.ashex` unless overridden with `--storage PATH`
- Default workspace: `~/Ashex/DefaultWorkspace`, created on first run when `--workspace` is not provided.

## CLI Options

- `onboard`: open the setup wizard even if saved settings already exist.
- `--workspace PATH`: workspace root enforced by `WorkspaceGuard`; overrides the default workspace.
- `--storage PATH`: persistence directory, default `WORKSPACE/.ashex`.
- `--onboarding`: alias for `onboard`.
- `--max-iterations N`: loop limit, default `8`.
- `--provider mock|openai|anthropic|ollama|dflash`: model adapter selection.
- `--model MODEL`: model name for provider-backed mode.
- `--approval-mode trusted|guarded`: execution policy, default `trusted`.

## Shell And Sandbox Policy

Shell policy config in `ashex.config.json`:

- `sandbox.mode`: `read_only`, `workspace_write`, or `danger_full_access`.
- `sandbox.protectedPaths`: workspace-relative paths that remain protected in `workspace_write` mode.
- `network.mode`: `allow`, `prompt`, or `deny` for network-affecting shell commands.
- `network.rules`: explicit network command prefix actions with `allow`, `prompt`, or `deny`.
- `allowList`: explicit command prefixes that are allowed to run.
- `denyList`: explicit command prefixes that are blocked.
- `rules`: explicit per-prefix actions with `allow`, `prompt`, or `deny`.
- `requireApprovalForUnknownCommands`: when enabled, commands outside configured allow rules or built-in recognized safe rules require approval in guarded mode.

## Guarded Mode

```bash
ashex --approval-mode guarded 'shell: pwd'
ashex --approval-mode guarded
```

In guarded mode:

- Shell commands require approval.
- Filesystem writes and mutating filesystem operations require approval.
- Read-only filesystem operations continue without prompting.
- Shell commands outside configured allow/safe rules can be escalated into the same approval flow.
- Read-only sandbox mode blocks filesystem mutations and mutating shell commands before approval logic runs.
- Workspace-write sandbox mode protects sensitive paths like `.git`, `.ashex`, `.codex`, and `ashex.config.json` by default.
- Network policy is enforced for shell execution, including the side terminal pane.

## Daemon And Telegram Config

- `daemon.enabled`: reserved toggle for daemon-oriented deployments.
- `logging.level`: `debug`, `info`, `warning`, or `error`.
- `telegram.enabled`: enables the Telegram connector for daemon runs.
- `telegram.botToken`: optional bot token if you do not want to use `ASHEX_TELEGRAM_BOT_TOKEN` or Keychain.
- `telegram.pollingTimeoutSeconds`: long-poll timeout for `getUpdates`.
- `telegram.accessMode`: `open` or `allowlist_only`.
- `telegram.allowedChatIDs`: optional allowlist of Telegram private chat IDs.
- `telegram.allowedUserIDs`: optional allowlist of Telegram user IDs.
- `telegram.responseMode`: currently `final_message`.
- `telegram.executionPolicy`: `assistant_only`, `approval_required`, or `trusted_full_access`.
- `ollama.requestTimeoutSeconds`: request timeout for Ollama chat and agent-mode requests, default `180`.
- `dflash.enabled`: optional toggle for the experimental DFlash provider.
- `dflash.baseURL`: local `dflash-serve` endpoint, default `http://127.0.0.1:8000`.
- `dflash.model`: default model for the DFlash provider.
- `dflash.draftModel`: optional draft model override for `dflash-serve`.
- `dflash.requestTimeoutSeconds`: request timeout for the DFlash server client.

## Safe Starting Config

```json
{
  "telegram": {
    "enabled": true,
    "accessMode": "allowlist_only",
    "executionPolicy": "assistant_only",
    "pollingTimeoutSeconds": 20,
    "allowedChatIDs": ["123456789"],
    "allowedUserIDs": ["123456789"]
  },
  "logging": {
    "level": "info"
  }
}
```

## TUI Controls

- `Tab`: cycle focus between launcher, settings/history panels, and input.
- `Workspaces`: inspect recent project roots and switch sessions without typing paths.
- `Up/Down` or `j/k`: move through launcher or panel selections.
- `Page Up` / `Page Down`: scroll transcripts or terminal output faster.
- `Home` / `End` or `g` / `G`: jump to the oldest output or back to the live tail.
- `Enter`: open the selected item or submit the current input.
- `Esc` or `Left`: back out, cancel, or quit.
- `t`: toggle the side terminal pane.
- `x`: skip the current planned step.
- `y` / `n`: approve or deny guarded actions.

## Live Workspace Commands

- `/workspace /full/path/to/project`: switch the current session to a different workspace.
- `/workspaces`: open the recent-workspaces picker.
- `/pwd`: show the current active workspace.
- `/sandbox`: show the current effective sandbox and command-policy state.
- `/toolpacks`: show bundled and custom installable tool packs.
- `/install-pack swiftpm`: enable a bundled installable tool pack.
- `/uninstall-pack python`: disable a bundled installable tool pack.
- Supported aliases: `:workspace /path`, `workspace /path`, `cd /path`, `/cd /path`.
