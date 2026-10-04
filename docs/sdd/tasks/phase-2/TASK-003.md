# TASK-003: Wrapper Script (ccorch-wrapper.sh)

## Status
TODO

## Description
Implement the wrapper script that launches Claude Code in child panes with signal guarantee, timeout enforcement, and atomic result file writes. This is the most critical component for reliability.

## Implementation Steps

1. Create `scripts/ccorch-wrapper.sh` based on the design spec:
   - Design: @../../../design/components/wrapper-script.md

2. Key features to implement:
   - `trap cleanup EXIT` for signal guarantee
   - Timeout watchdog (background subshell with `sleep` + `kill 0`)
   - Atomic result file writes (tmp → mv)
   - Depth-based `--disallowedTools` construction and `--permission-mode auto` (0.6.0; see [DEC-006](../../design/decisions/DEC-006.md))
   - Start gate for the depth, pane and children limits (0.6.0)
   - System prompt injection via `--append-system-prompt`
   - Child ID generation (`depth${DEPTH}-$$-${RANDOM}` since 0.6.0)

3. Environment variable validation:
   ```bash
   DEPTH="${CCORCH_DEPTH:?CCORCH_DEPTH is required}"
   SESSION_ID="${CCORCH_SESSION_ID:?CCORCH_SESSION_ID is required}"
   PARENT_CHANNEL="${CCORCH_PARENT_CHANNEL:?CCORCH_PARENT_CHANNEL is required}"
   WORK_DIR="${CCORCH_WORK_DIR:?CCORCH_WORK_DIR is required}"
   ```

4. Make executable: `chmod +x scripts/ccorch-wrapper.sh`

## Acceptance Criteria
- [ ] Script is executable (`chmod +x`)
- [ ] Validates required environment variables with clear error messages
- [ ] `trap EXIT` guarantees signal delivery to parent
- [ ] Timeout watchdog kills process and writes timeout result
- [ ] Result files are written atomically (tmp → mv)
- [ ] DEPTH=3 denies `Agent` and `Bash(tmux *)` through `--disallowedTools`
- [ ] DEPTH=1/2 do not deny the Agent tool or tmux Bash patterns
- [ ] Start gate refuses a pane over the depth, pane or children limits (`status: refused`)
- [ ] No hardcoded paths (uses env vars)
- [ ] Handles task descriptions with special characters (quotes, newlines)

## Testing Notes
- Test normal completion → result file + signal
- Test timeout → timeout result + signal + process killed
- Test crash (kill -9) → error result + signal (via trap)
- Test DEPTH=3 → `Agent` and `Bash(tmux *)` in `--disallowedTools` (`tests/test_wrapper.sh`, dry run)

## Related
- Design: @../../../design/components/wrapper-script.md
- Requirements: US-003 (communication), US-004 (safety)
