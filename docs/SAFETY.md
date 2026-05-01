# Safety

ASHEX safety layers include:

- workspace guard and protected paths
- shell/network policy assessment
- guarded approval mode
- typed tool contracts with mutating-operation, network, approval, timeout, idempotency, and side-effect metadata
- prompt-injection scanning for context and skills
- obvious secret redaction before memory writes
- memory audit JSONL
- quarantine-first skill installation

Tool side-effect labels are `readOnly`, `localWrite`, `network`, `shellCommand`, `destructive`, and `credentialSensitive`. Prompt assembly exposes these labels as routing hints so the model prefers read-only tools during exploration and reserves higher-risk operations for work that actually needs them.

Shell execution policy requires approval for recognized destructive or privilege-elevated commands, including recursive removal, hard reset, force clean, recursive ownership/permission changes, force kills, disk erase/partition commands, raw disk writes, and `sudo`. It also requires approval for commands that appear to read, print, or export credentials, such as keychain reads, password-manager reads, secret environment variables, and common private-key or credential files.

High-risk future surfaces such as live MCP tools, RPC, background process writes, and automatic skill amendments must reuse these layers rather than creating direct bypasses.
