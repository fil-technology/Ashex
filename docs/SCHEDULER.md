# Scheduler

ASHEX already has cron parsing and persisted cron job records in `CronJobs.swift`.

Useful command surface:

```bash
ashex cron list
ashex cron add --id daily --schedule "0 9 * * *" --prompt "Summarize project health"
ashex cron remove --id daily
```

The new agent layout also creates `cron/jobs.toml` and `cron/history.jsonl` for future human-editable schedule files and run history.

