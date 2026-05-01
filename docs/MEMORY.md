# Memory

ASHEX keeps curated Markdown memory files:

- `memory/MEMORY.md`: agent facts and durable notes
- `memory/USER.md`: user preferences and profile
- `memory/PROJECTS.md`: cross-project notes
- `memory/LESSONS.md`: failures, fixes, and reusable learnings
- `.ashex/memory/project.md`: repo-specific memory

Commands:

```bash
ashex memory list
ashex memory show memory
ashex memory add memory "Use swift test before finishing"
ashex memory search "swift test"
ashex memory replace memory "old text" "new text"
ashex memory remove memory "unique text"
```

Writes are redacted for obvious secret patterns and appended to `memory/audit.jsonl`.

