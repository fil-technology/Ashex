# Skills

ASHEX supports portable `SKILL.md` folders as procedural memory.

Skill directories can contain:

```text
SKILL.md
_meta.json
scripts/
examples/
references/
```

Commands:

```bash
ashex skills install ./my-skill
ashex skills list
ashex skills show my-skill
ashex skills audit my-skill
ashex skills validate my-skill
ashex skills route "run swift test and fix compile failures"
ashex skills quarantine my-skill
ashex skills create draft-skill
ashex skills export my-skill
ashex skills remove my-skill
```

Installs go to quarantine first. Audit scans `SKILL.md` for prompt-injection patterns. Enabling quarantined skills is available through the runtime `agent_knowledge.skills_enable` operation.

Routing reads enabled skills from disk and uses `trigger_phrases` plus `required_tools` frontmatter when present. Validation reports missing `SKILL.md`, frontmatter/name mismatches, quarantine state, and prompt-injection findings before a skill is routed.

Skills may also include optional Open Design-inspired metadata without adding any dependency on `nexu-io/open-design`:

```yaml
capabilities_required: sandboxed_preview, artifact_manifest
od.mode: review
od.inputs: design-system.md, manifest.json
```

These fields are advisory. ASHEX preserves normal `SKILL.md` compatibility when they are absent, warns during validation when declared capabilities are unavailable, and ranks skills lower when required capabilities cannot be satisfied.
