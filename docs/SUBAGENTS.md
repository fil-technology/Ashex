# Subagents

ASHEX has runtime-level delegation through `DelegationStrategy` and child agent loops for bounded workstreams.

Subagent runs now create workspace leases under:

```text
.ashex/subagents/<run-id>/<lease-id>/lease.json
```

The default runtime mode is `shared_read_only`, which records the shared workspace and keeps delegated work bounded by read-only tool scopes. `SubagentWorkspaceManager` also supports `copied_writable` leases for future mutation-capable subagents; copied workspaces skip heavy or private state such as `.git`, `.ashex`, `.build`, `.swiftpm`, `DerivedData`, and `node_modules`.

The desired management surface is:

```bash
ashex subagents list
ashex subagents spawn
ashex subagents stop <id>
ashex subagents logs <id>
```

Those commands are not active yet. The TUI Agent Ops screen already lists recorded subagent workspace leases. Subagents should remain read-only by default and should only mutate copied or explicitly approved workspaces.
