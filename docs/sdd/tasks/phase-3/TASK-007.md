# TASK-007: Integration Smoke Test

## Status
IN PROGRESS. The 0.6.0 live check on 2026-10-04 (issue #11) covered part of step 3 and the limit
refusals of DEC-006. The plugin was updated from 0.5.0 to 0.6.0 from the marketplace with
`claude plugin update ccorch@levnas-plugins`; a fresh `/plugin install` (step 1) was not run.
Steps 2, 4, 5 and 6 had not been run live. The 0.6.1 live check (2026-10-05) stopped at a
read-outside-the-working-directories prompt, fixed in 0.6.2; the 0.6.2 live check the same day passed
(issue #11), but it started the Main Brain with a script, not `/ccor`. The 0.6.3 live check the
same day ran `/ccor` typed by the user, a child that runs and a SIGKILLed child (DEC-006,
Consequences); step 2 was partly run, and steps 4, 5 and 6 are still not run live.

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
- [ ] Plugin installs successfully from marketplace (only an update from the marketplace was run, 2026-10-04)
- [ ] Precondition checks work correctly (partly, 0.6.3, 2026-10-05: `/ccor` in a session with no `TMUX` stopped at step 1 with "Error: Must run inside a tmux session". `/ccor` with no task has no usage-hint step in SKILL.md, and it was not observed)
- [ ] Basic orchestration completes with result.md (0.6.3, 2026-10-05, with `/ccor` typed by the user in a session in accept-edits mode: the wait loop ran in the background and the session's turn ended before the notification; the notification came when `result.md` appeared; the result was presented and the session asked before closing the Main Brain's pane. Not checked off, because two commands in that session stopped for approval: one the session composed itself to show the result, and step 7's own close loop.
  Earlier: 0.6.0, 2026-10-04: the Main Brain pane ran and `result.md` matched its result, but only after a human sent `/exit`, and both runs stopped once at a user's ask rule on `mv` until a human answered; the return to interactive mode and the completion notification were not checked. 0.6.2, 2026-10-05: `result.md` existed at the first signal, while the Main Brain was still running, with no prompt and no `/exit`; the Main Brain was started by a script and a logger received the signal, so `/ccor`'s return to interactive mode and its notification are still not checked)
- [ ] Depth limit is enforced (not run live; grandchildren were left out to keep two panes at a time)
- [ ] Timeout mechanism works (not run live.
  0.6.3, 2026-10-05: a finished Main Brain's pane stayed open past `CCORCH_TIMEOUT`, consistent with the watchdog acting only on a pane with no result)

## Notes
- This is a manual smoke test, not automated
- Run in a tmux session with sufficient pane space
- Monitor system resources during test (especially if ccresmon is installed)

## Related
- All requirements and design documents
