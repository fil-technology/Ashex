# Task Queue

The runtime already persists runs, run steps, events, tool calls, working memory, and session inspection data in SQLite.

The file layout now reserves:

```text
tasks/
  <task-id>/
    task.json
    plan.md
    logs.jsonl
    result.md
```

The explicit `ashex tasks` queue commands manage durable task records:

```bash
ashex tasks new --plan "Inspect, patch, test" "Fix the parser"
ashex tasks list
ashex tasks claim worker-1
ashex tasks done <task-id> "Completed"
ashex tasks fail <task-id> "Blocked"
ashex tasks retry <task-id>
ashex tasks heartbeat
ashex tasks requeue-stale
```

The queue is a coordination primitive. Runtime dispatch should still reuse the existing run dispatcher and approval system instead of creating a second execution path.
