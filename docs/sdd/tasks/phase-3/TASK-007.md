# TASK-007: Integration Smoke Test

## Status
IN PROGRESS. The 0.6.0 live check on 2026-10-04 (issue #11) covered steps 1 and 3 and the
limit refusals of DEC-006. Steps 2, 4 and 5 have not been run live, and 0.6.1 has not had a live check.

## Description
Verify that the complete flow works end-to-end: plugin installation, skill invocation, pane creation, task execution, and result retrieval.

## Test Steps

1. **Plugin install test**:
   ```
   /plugin install ccorch@levnas-plugins
   ```
   - Verify plugin appears in installed plugins list

2. **Precondition check test**:
   - Run `/ccor` outside tmux → expect error message
   - Run `/ccor` without task → expect usage hint

3. **Basic orchestration test**:
   ```
   /ccor "List all .md files in this repository and count them"
   ```
   - Verify Main Brain pane is created
   - Verify user session returns to interactive mode
   - Verify result.md is created in /tmp/ccorch/
   - Verify completion notification is received

4. **Depth limit test**:
   - Verify DEPTH=3 panes cannot create child panes (flags and system prompt; see NFR-SEC-003 for what is verified)

5. **Timeout test** (manual):
   - Set CCORCH_TIMEOUT=10
   - Give a task that takes longer than 10 seconds
   - Verify timeout result is generated

6. **Cleanup verification**:
   - Check /tmp/ccorch/ contains session directory
   - Verify no files leaked into the repository

## Acceptance Criteria
- [x] Plugin installs successfully from marketplace (0.6.0, 2026-10-04)
- [ ] Precondition checks work correctly
- [x] Basic orchestration completes with result.md (0.6.0, 2026-10-04; `result.md` was written when the Main Brain's pane exited)
- [ ] Depth limit is enforced
- [ ] Timeout mechanism works

## Notes
- This is a manual smoke test, not automated
- Run in a tmux session with sufficient pane space
- Monitor system resources during test (especially if ccresmon is installed)

## Related
- All requirements and design documents
