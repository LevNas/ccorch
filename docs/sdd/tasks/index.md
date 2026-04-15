# Tasks

> This document assumes implementation by AI agents (Claude Code, etc.).

## Explicitly Specified Information

- [x] Target directory: `~/src/github.com/LevNas/ccorch/`
- [x] Language: Bash (wrapper script), Markdown (SKILL.md, plugin.json)
- [x] License: MIT
- [x] Plugin format: Claude Code plugin (`.claude-plugin/plugin.json`)
- [x] Distribution: claudecode-plugins marketplace
- [x] Convention: Public repo — all code and docs in English

## No Unknown Information

All implementation details have been defined in the design phase.

---

## Progress Summary

| Phase | Done | In Progress | TODO | Blocked | Details |
|-------|------|-------------|------|---------|---------|
| Phase 1: Plugin Scaffold | 2 | 0 | 0 | 0 | [Details](phase-1/) @phase-1/ |
| Phase 2: Core Implementation | 3 | 0 | 0 | 0 | [Details](phase-2/) @phase-2/ |
| Phase 3: Distribution | 1 | 0 | 0 | 1 | [Details](phase-3/) @phase-3/ |

## Task List

### Phase 1: Plugin Scaffold
*Estimated: 10 min*

| Task ID | Title | Status | Depends | Est. | Details |
|---------|-------|--------|---------|------|---------|
| TASK-001 | Plugin metadata and directory structure | DONE | - | 5min | [Details](phase-1/TASK-001.md) @phase-1/TASK-001.md |
| TASK-002 | LICENSE and README | DONE | - | 5min | [Details](phase-1/TASK-002.md) @phase-1/TASK-002.md |

### Phase 2: Core Implementation
*Estimated: 25 min*

| Task ID | Title | Status | Depends | Est. | Details |
|---------|-------|--------|---------|------|---------|
| TASK-003 | Wrapper script (ccorch-wrapper.sh) | DONE | TASK-001 | 10min | [Details](phase-2/TASK-003.md) @phase-2/TASK-003.md |
| TASK-004 | SKILL.md (/ccor skill definition) | DONE | TASK-003 | 10min | [Details](phase-2/TASK-004.md) @phase-2/TASK-004.md |
| TASK-005 | System prompt templates | DONE | TASK-004 | 5min | [Details](phase-2/TASK-005.md) @phase-2/TASK-005.md |

### Phase 3: Distribution
*Estimated: 10 min*

| Task ID | Title | Status | Depends | Est. | Details |
|---------|-------|--------|---------|------|---------|
| TASK-006 | Marketplace registration | DONE | Phase 2 | 5min | [Details](phase-3/TASK-006.md) @phase-3/TASK-006.md |
| TASK-007 | Integration smoke test | BLOCKED | TASK-006 | 5min | [Details](phase-3/TASK-007.md) @phase-3/TASK-007.md |

---

## Risks

| Risk | Impact | Probability | Mitigation |
|------|--------|-------------|------------|
| `--allowedTools` Bash pattern syntax changes in future Claude Code versions | Medium | Low | Pin to documented syntax, test on upgrade |
| tmux wait-for channel name collision across concurrent sessions | Low | Low | Session ID includes timestamp |
| Wrapper script quoting issues with complex task descriptions | Medium | Medium | Test with special characters, use heredoc |

## Notes

- TASK-001 and TASK-002 are independent — can be done in parallel
- TASK-003 is the most critical component (reliability depends on it)
- TASK-005 can be merged into TASK-004 if system prompts are simple enough
