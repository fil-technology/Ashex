# ASHEX Agent Architecture

ASHEX now has a local-first durable agent layer alongside the existing runtime loop.

## Implemented Surface

- `AgentHome` initializes the global/project file layout under the selected storage root and workspace.
- `AgentContextLoader` loads SOUL, user memory, agent memory, project context, compatible instruction files, and lazy nested `AGENTS.md` files.
- `AgentMemoryStore` manages Markdown memory files with append, replace, remove, search, redaction, and audit logging.
- `AgentSkillStore` supports portable `SKILL.md` folders, quarantine-first install, metadata parsing, audit, enable, show, list, remove, and generated drafts.
- `AgentMCPRegistry` persists stdio/HTTP MCP server config with allow/deny tool filters.
- `AgentKnowledgeBase` initializes and maintains an OpenKB-style Markdown wiki under `.ashex/kb`.
- `AgentKnowledgeTool` exposes context, memory, skills, MCP config, and KB operations through the existing tool registry.

## Commands

Use `ashex context`, `ashex soul`, `ashex memory`, `ashex skills`, `ashex mcp`, `ashex kb`, and `ashex doctor`.

## Safety

All runtime access goes through the typed tool contract and existing approval path. File-backed stores redact obvious secrets and scan context/skill text for prompt-injection patterns.

