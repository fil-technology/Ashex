# Context Files

ASHEX loads durable context in this order:

1. `SOUL.md`
2. `memory/USER.md`
3. `memory/MEMORY.md`
4. project `.ashex.md`
5. project `ASHEX.md`
6. project `AGENTS.md`
7. compatible files: `CLAUDE.md`, `.cursorrules`, `.cursor/rules/*.mdc`
8. nested `AGENTS.md` discovered for an operation path

Run:

```bash
ashex context init
ashex context list
ashex context doctor
```

Context files are budgeted per file and scanned for phrases that look like prompt injection before use.

