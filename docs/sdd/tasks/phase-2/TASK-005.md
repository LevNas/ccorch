# TASK-005: System Prompt Templates

## Status
TODO

## Description
Define the system prompts injected at each depth level via `--append-system-prompt`. These prompts are the behavioral contracts for each orchestration level.

## Implementation Steps

1. Define prompts for each depth level in the SKILL.md or as separate template files.

### DEPTH=1 (Main Brain) Prompt

Key sections:
- Role and responsibilities
- Child pane creation instructions (how to call wrapper script)
- Result aggregation procedure
- Safety rules (no destructive git ops)
- ccmemo integration (conditional)
- Worktree decision guidance
- Environment variable reference

### DEPTH=2 (Child) Prompt

Key sections:
- Role: execute assigned subtask
- Can create grandchild panes (DEPTH=3)
- Must write results to CCORCH_WORK_DIR
- Safety rules
- Signal parent on completion

### DEPTH=3 (Grandchild) Prompt

Key sections:
- Role: execute assigned task only
- Cannot create new panes
- Must write results to CCORCH_WORK_DIR
- Signal parent on completion

2. Result file format template:
   ```markdown
   ---
   status: success | error | timeout
   depth: N
   task: "brief description"
   completed: ISO-8601
   ---

   # Results
   ## Execution Summary
   ## Changed Files
   ## Discoveries
   ```

## Acceptance Criteria
- [ ] Each depth has a distinct, clear system prompt
- [ ] DEPTH=3 prompt explicitly states "do not create panes"
- [ ] Result file format is documented and consistent
- [ ] Prompts reference correct environment variables
- [ ] All prompts are in English

## Related
- Design: @../../../design/index.md (Security Considerations, Guard Rail System Prompts)
- Requirements: US-004 (REQ-004-004)
