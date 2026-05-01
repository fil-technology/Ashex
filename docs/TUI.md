# TUI

The existing TUI supports chat, provider switching, workspace switching, history browsing, side terminal behavior, runtime events, guarded approvals, and an Agent Ops overview.

Agent Ops is available from the launcher. It summarizes:

- task queue counts, recent tasks, and stale heartbeat detections
- managed processes and recent process state
- subagent workspace leases
- installed/quarantined/generated skills
- configured MCP servers and the runtime MCP bridge
- model route slots by task purpose
- knowledge-base lint health

This is the first management screen. Deeper drill-down screens for memory, schedules, logs, approvals, and interactive subagent controls remain future UI depth.
