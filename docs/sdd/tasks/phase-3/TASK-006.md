# TASK-006: Marketplace Registration

## Status
TODO

## Description
Add ccorch to the claudecode-plugins marketplace so users can install via `/plugin install ccorch@levnas-plugins`.

## Implementation Steps

1. Edit `~/src/github.com/LevNas/claudecode-plugins/.claude-plugin/marketplace.json`:
   - Add ccorch entry to the `plugins` array:
   ```json
   {
     "name": "ccorch",
     "description": "tmux-based orchestration plugin for Claude Code. Provides /ccor skill for multi-level task delegation.",
     "source": {
       "source": "url",
       "url": "https://github.com/LevNas/ccorch.git",
       "ref": "main"
     },
     "homepage": "https://github.com/LevNas/ccorch"
   }
   ```

2. Update `~/src/github.com/LevNas/claudecode-plugins/README.md`:
   - Add ccorch row to the Available Plugins table

## Acceptance Criteria
- [ ] marketplace.json is valid JSON with ccorch entry
- [ ] README.md lists ccorch with install command
- [ ] Source URL points to correct repository

## Notes
- This task modifies the claudecode-plugins repo, not the ccorch repo
- Requires separate commit in claudecode-plugins

## Related
- Requirements: US-006 (REQ-006-002)
