# MCP

ASHEX stores MCP server configuration under `mcp/servers.json`.

Commands:

```bash
ashex mcp add github --transport stdio --command npx --args -y,@modelcontextprotocol/server-github
ashex mcp list
ashex mcp tools github
ashex mcp resources github
ashex mcp prompts github
ashex mcp call github get_issue --json '{"owner":"openai","repo":"codex","issue_number":1}'
ashex mcp remove github
ashex mcp reload
ashex mcp serve
```

The registry records transport, command or URL, enabled state, and allow/deny tool filters. Live discovery supports MCP stdio servers and Streamable HTTP JSON-RPC endpoints for `tools/list`, `resources/list`, and `prompts/list`.

`ashex mcp reload` now validates persisted server entries and converts them into runtime discovery descriptors with stable namespaces. The in-process `agent_knowledge.mcp_discovery_config` operation exposes the same descriptors for agent/runtime callers.

Runtime agents also get an `mcp` tool. `mcp.list` discovers external tools/resources/prompts, and `mcp.call` bridges to external `tools/call` with normal ASHEX tool-call persistence and guarded-mode approval prompts.

`ashex mcp serve` exposes ASHEX runtime tools over a stdio MCP server. It supports `initialize`, `ping`, `tools/list`, and `tools/call`; calls reuse the existing in-process RPC policy, so tools requiring approval are denied instead of bypassing policy.
