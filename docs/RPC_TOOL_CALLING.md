# RPC Tool Calling

```bash
ashex rpc list-tools
ashex rpc call agent_knowledge --json '{"operation":"context_list"}'
ashex rpc serve
```

`ashex rpc serve` opens a JSON-lines stdio server. Each input line is an `AgentRPCRequest`, and each output line is an `AgentRPCResponse`.

Supported methods:

- `tools/list`
- `tools/call`

Tool calls go through `AgentRPCStaticPolicy`, so tools that require approval are denied instead of silently executing outside the normal policy path.
