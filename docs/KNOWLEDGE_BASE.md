# Knowledge Base

ASHEX includes an OpenKB-inspired compiled Markdown wiki under:

```text
.ashex/kb/
  raw/
  wiki/
    index.md
    log.md
    AGENTS.md
    sources/
    summaries/
    concepts/
    explorations/
    reports/
  config.yaml
  sessions/
```

Commands:

```bash
ashex kb init
ashex kb add notes.md
ashex kb query "durable memory"
ashex kb lint
ashex kb list
ashex kb status
ashex kb chat "what do we know about durable memory?"
ashex kb watch docs --once
ashex kb save-exploration investigation "What we learned..."
```

The current ingestion path supports local Markdown/text/code-like files, preserves source provenance, writes summaries, updates the index/log, and lints missing sources.

`ashex kb chat` is a retrieval-oriented answer view over the compiled wiki. `ashex kb watch` tracks source fingerprints in `.ashex/kb/sessions/watch-state.json` and ingests only changed source files; omit `--once` to keep polling.
