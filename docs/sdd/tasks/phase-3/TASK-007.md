# TASK-007: Integration Smoke Test

## Status
TODO

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
   - Verify DEPTH=3 panes cannot create child panes (Agent tool disabled)

5. **Timeout test** (manual):
   - Set CCORCH_TIMEOUT=10
   - Give a task that takes longer than 10 seconds
   - Verify timeout result is generated

6. **Cleanup verification**:
   - Check /tmp/ccorch/ contains session directory
   - Verify no files leaked into the repository

## Acceptance Criteria
- [ ] Plugin installs successfully from marketplace
- [ ] Precondition checks work correctly
- [ ] Basic orchestration completes with result.md
- [ ] Depth limit is enforced
- [ ] Timeout mechanism works

## Notes
- This is a manual smoke test, not automated
- Run in a tmux session with sufficient pane space
- Monitor system resources during test (especially if ccresmon is installed)

## Related
- All requirements and design documents
