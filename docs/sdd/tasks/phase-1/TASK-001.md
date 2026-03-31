# TASK-001: Plugin Metadata and Directory Structure

## Status
TODO

## Description
Create the ccorch plugin directory structure and plugin.json metadata file.

## Implementation Steps

1. Create directory structure:
   ```
   ccorch/
   ├── .claude-plugin/
   │   └── plugin.json
   ├── skills/
   │   └── ccor/
   │       └── SKILL.md          # placeholder
   └── scripts/
       └── ccorch-wrapper.sh     # placeholder
   ```

2. Create `.claude-plugin/plugin.json`:
   ```json
   {
     "name": "ccorch",
     "description": "tmux-based orchestration plugin for Claude Code. Provides /ccor skill for multi-level task delegation.",
     "version": "0.1.0",
     "author": "LevNas",
     "license": "MIT",
     "keywords": ["orchestration", "tmux", "parallel", "delegation"]
   }
   ```

## Acceptance Criteria
- [ ] `.claude-plugin/plugin.json` exists and is valid JSON
- [ ] Directory structure matches the spec
- [ ] Placeholder files created for SKILL.md and ccorch-wrapper.sh

## Related
- Design: @../../../design/index.md (File Structure section)
- Requirement: US-006 (plugin structure)
