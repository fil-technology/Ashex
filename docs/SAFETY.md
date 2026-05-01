# Safety

ASHEX safety layers include:

- workspace guard and protected paths
- shell/network policy assessment
- guarded approval mode
- typed tool contracts with mutating-operation metadata
- prompt-injection scanning for context and skills
- obvious secret redaction before memory writes
- memory audit JSONL
- quarantine-first skill installation

High-risk future surfaces such as live MCP tools, RPC, background process writes, and automatic skill amendments must reuse these layers rather than creating direct bypasses.

