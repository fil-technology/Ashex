# Ashex Production Readiness Checklist

This checklist tracks the remaining work between Ashex's current production-shaped architecture and a more reliably production-ready coding agent.

## Current Focus

- [x] Stronger real-project validation execution
- [x] Safer parallel delegated exploration and validation
- [ ] Smarter repo preflight and file targeting
- [ ] Richer multi-file patch coordination on real code changes
- [ ] Stronger long-session continuity on messy tasks
- [ ] More mature managed multi-agent coordination
- [ ] Harder execution sandboxing and network-policy observability

## Smarter Repo Preflight And File Targeting

- [x] Persist a richer workspace snapshot with project markers and likely source/test roots
- [x] Surface repo profile details in prompts and history
- [x] Bias exploration toward source roots, test roots, markers, and instruction files
- [ ] Prefer framework-aware entry points more aggressively on larger repos
- [ ] Track rejected or exhausted targets so repeated scans are reduced

## Stronger Validation Quality

- [x] Run proactive validation for SwiftPM, JavaScript package managers, Rust, and Go
- [x] Add typed SwiftPM and Xcode build/test actions instead of relying only on raw shell commands
- [ ] Add more framework-aware validations for Python, Ruby, and containerized projects
- [ ] Distinguish "validation attempted" from "validation passed" more clearly in final summaries
- [ ] Prefer targeted test scopes when enough file/module context is available

## Multi-File Change Reliability

- [x] Persist patch plan targets and objectives
- [ ] Add per-file intent and per-file completion state
- [ ] Show pending versus completed file work more clearly in the TUI
- [ ] Improve rollback guidance when a larger plan drifts

## Long-Session And Resume Quality

- [x] Persist working memory, compactions, and carry-forward notes
- [ ] Reduce stale repeated context more aggressively after long runs
- [ ] Preserve stronger task continuity across resumed sessions
- [ ] Surface compacted memory more explicitly in history review

## Managed Multi-Agent Coordination

- [x] Support bounded delegated subtasks
- [x] Support bounded read-only parallel exploration/validation lanes
- [ ] Add stronger ownership/result integration for multi-file delegated work
- [ ] Improve handoff quality for follow-up mutation and validation steps

## Safety And Sandboxing

- [x] Separate approval policy from sandbox policy
- [x] Add workspace sandbox modes and network policy
- [ ] Increase execution-time sandbox isolation beyond policy enforcement
- [ ] Improve visibility of why commands were allowed, prompted, or denied
