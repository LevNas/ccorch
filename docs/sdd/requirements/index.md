# Requirements Definition

## Overview

ccorch is a tmux-based orchestration plugin for Claude Code. Running the `/ccor` skill from a user's Claude Code session automatically creates a Main Brain pane, which delegates tasks through a 3-level hierarchy (Main Brain → Child → Grandchild) for parallel execution. Completion signals are delivered via `tmux wait-for`, and results are aggregated through file-based communication.

## User Stories

| ID | Title | Priority | Status | Details |
|----|-------|----------|--------|---------|
| US-001 | Orchestration Execution | High | Approved | [Details](stories/US-001.md) @stories/US-001.md |
| US-002 | 3-Level Depth Control | High | Approved | [Details](stories/US-002.md) @stories/US-002.md |
| US-003 | tmux wait-for Communication | High | Approved | [Details](stories/US-003.md) @stories/US-003.md |
| US-004 | Multi-Layer Safety | High | Approved | [Details](stories/US-004.md) @stories/US-004.md |
| US-005 | ccmemo Integration | Medium | Approved | [Details](stories/US-005.md) @stories/US-005.md |
| US-006 | Marketplace Distribution | Medium | Approved | [Details](stories/US-006.md) @stories/US-006.md |

## Functional Requirements Summary

| Req ID | Description | Related Story | Status |
|--------|-------------|---------------|--------|
| REQ-001 | `/ccor` skill creates Main Brain pane automatically | US-001 | Defined |
| REQ-002 | User session continues parallel work after launch | US-001 | Defined |
| REQ-003 | Depth propagation via CCORCH_DEPTH env var | US-002 | Defined |
| REQ-004 | Structurally prohibit pane creation at DEPTH=3 | US-002 | Defined |
| REQ-005 | tmux wait-for based signaling | US-003 | Defined |
| REQ-006 | File-based data exchange via /tmp/ccorch/<session_id>/ | US-003 | Defined |
| REQ-007 | Timeout to prevent infinite blocking | US-003 | Defined |
| REQ-008 | Depth-based tool restrictions via --allowedTools | US-004 | Defined |
| REQ-009 | Guard rails via --append-system-prompt | US-004 | Defined |
| REQ-010 | ccmemo record-knowledge / plan-task integration | US-005 | Defined |
| REQ-011 | Standalone operation without ccmemo | US-005 | Defined |
| REQ-012 | claudecode-plugins marketplace.json registration | US-006 | Defined |

## Non-Functional Requirements

| Category | Details | Count |
|----------|---------|-------|
| Security | [Details](nfr/security.md) @nfr/security.md | 4 |
| Reliability | [Details](nfr/reliability.md) @nfr/reliability.md | 3 |
| Resource Constraints | [Details](nfr/resource.md) @nfr/resource.md | 2 |

## Dependencies

- **tmux** 1.8+: Required for `wait-for` command support
- **Claude Code CLI**: Requires `--dangerously-skip-permissions`, `--allowedTools`, `--append-system-prompt`, `-p` flags
- **ccmemo** (optional): Integration features activate only when installed

## Out of Scope

- GUI / Web UI
- Non-tmux terminal multiplexer support (zellij, screen, etc.)
- Depth beyond 3 levels
- Cross-machine remote orchestration
- Interactive mode for child panes (`-p` one-shot only)

---

## Document Structure

```
docs/sdd/requirements/
├── index.md                 # This file (table of contents)
├── stories/
│   ├── US-001.md           # Orchestration Execution
│   ├── US-002.md           # 3-Level Depth Control
│   ├── US-003.md           # tmux wait-for Communication
│   ├── US-004.md           # Multi-Layer Safety
│   ├── US-005.md           # ccmemo Integration
│   └── US-006.md           # Marketplace Distribution
└── nfr/
    ├── security.md         # Security requirements
    ├── reliability.md      # Reliability requirements
    └── resource.md         # Resource constraints
```
