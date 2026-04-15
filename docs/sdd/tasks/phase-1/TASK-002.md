# TASK-002: LICENSE and README

## Status
TODO

## Description
Create MIT LICENSE file and README.md with installation instructions, usage, and prerequisites.

## Implementation Steps

1. Create `LICENSE` with MIT license text (author: LevNas, year: 2026)

2. Create `README.md`:
   ```markdown
   # ccorch

   tmux-based orchestration plugin for Claude Code.

   ## Prerequisites
   - tmux 1.8+
   - Claude Code CLI

   ## Installation
   /plugin marketplace add LevNas/claudecode-plugins
   /plugin install ccorch@levnas-plugins

   ## Usage
   /ccor <task description>

   ## How It Works
   - 3-level hierarchy (Main Brain → Child → Grandchild)
   - tmux wait-for signaling
   - File-based result exchange

   ## Optional Integration
   - ccmemo: knowledge persistence
   - ccresmon: resource monitoring

   ## License
   MIT
   ```

## Acceptance Criteria
- [ ] LICENSE file exists with correct MIT text
- [ ] README.md covers: prerequisites, installation, usage, architecture overview
- [ ] No Japanese text (public repo)

## Related
- Requirement: US-006 (REQ-006-003)
