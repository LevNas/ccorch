# TASK-004: SKILL.md (/ccor Skill Definition)

## Status
TODO

## Description
Create the SKILL.md that defines the `/ccor` skill — the entry point for orchestration. This instructs Claude Code on how to launch orchestration when the user invokes `/ccor`.

## Implementation Steps

1. Create `skills/ccor/SKILL.md` based on the design spec:
   - Design: @../../../design/components/skill.md

2. Skill structure:
   ```markdown
   # ccor

   ## Trigger
   User invokes /ccor with a task description.

   ## Precondition Checks
   - tmux available
   - Inside tmux session
   - Not already inside orchestration (CCORCH_DEPTH unset)

   ## Procedure
   1. Generate session ID and work directory
   2. Launch Main Brain via tmux new-window + wrapper script
   3. Set up background completion wait (run_in_background)
   4. Return control to user
   5. On completion signal, read and present results
   ```

3. Include the Main Brain system prompt (DEPTH=1 rules, child creation instructions, result aggregation instructions)

4. Include ccmemo integration detection logic

5. Include worktree decision guidance

## Acceptance Criteria
- [ ] SKILL.md is a valid Claude Code skill definition
- [ ] Precondition checks prevent double-orchestration and non-tmux usage
- [ ] Main Brain system prompt includes: delegation rules, safety rules, result aggregation, signaling
- [ ] ccmemo integration is conditional (auto-detected)
- [ ] Worktree usage guidance is included
- [ ] Script path references use `$CLAUDE_PLUGIN_ROOT` or relative paths

## Related
- Design: @../../../design/components/skill.md
- Design: @../../../design/components/result-aggregator.md (aggregation logic in system prompt)
- Requirements: US-001, US-005
