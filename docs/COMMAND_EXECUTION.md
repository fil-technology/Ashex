# Command Execution

ASHEX already executes foreground shell commands through the `shell` tool and `ashex exec`.

Current behavior:

- workspace working directory support
- stdout/stderr streaming into runtime events
- timeout support
- shell/network/sandbox policy assessment
- guarded approval mode for commands outside allow rules

The Hermes prompt also asks for persistent background process actions: list, poll, log, wait, kill, and write. Those remain a separate process-manager phase.

