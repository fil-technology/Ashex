# AGENTS.md

`AGENTS.md` is project operational context. It should describe architecture, conventions, commands, paths, ports, workflows, and validation steps.

ASHEX reads the project-root `AGENTS.md` during context loading. For file or tool operations inside subdirectories, nested `AGENTS.md` files are discovered lazily so package-specific rules can be applied without loading the entire repo.

Create starter files:

```bash
ashex context init
```

