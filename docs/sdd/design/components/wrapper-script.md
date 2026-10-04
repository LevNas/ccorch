# Component: Wrapper Script (`ccorch-wrapper.sh`)

## Purpose

Launches Claude Code in a child pane with proper environment setup, a start gate for the depth and pane limits, signal guarantee on exit, and timeout enforcement. This is the critical reliability component — it ensures the parent always receives a signal, even on crashes or refusals.

## Location

`scripts/ccorch-wrapper.sh`

## Interface

```bash
ccorch-wrapper.sh <task_description>
```

### Environment Variables

| Variable | Description |
|----------|-------------|
| `CCORCH_DEPTH` | Required. Current depth (1, 2, or 3) |
| `CCORCH_SESSION_ID` | Required. Session identifier |
| `CCORCH_PARENT_CHANNEL` | Required. Channel to signal parent on completion |
| `CCORCH_WORK_DIR` | Required. Directory for result files |
| `CCORCH_PROJECT_DIR` | Required. Directory `claude` runs in |
| `CCORCH_TIMEOUT` | Timeout in seconds (default: 600) |
| `CCORCH_MAX_PANES` | Maximum live ccorch panes, Main Brain included (default: 8) |
| `CCORCH_MAX_CHILDREN_D1` | Max live children of the Main Brain (default: 3) |
| `CCORCH_MAX_CHILDREN_D2` | Max live grandchildren per Child (default: 2) |
| `CCORCH_PARENT_ID` | The parent's child ID; required at depth 2 and 3, unset at depth 1 |
| `CCORCH_DRY_RUN` | If set: run the gate, print the `claude` argv, exit 0 without starting `claude` |

## Script Flow

1. Validate inputs; `cd` to the project directory.
2. Generate `CHILD_ID` (`depth<N>-<6 digits>`), `RESULT_FILE`, and install `trap cleanup EXIT`. The trap must exist before the gate so a refusal reaches the parent.
3. **Start gate** (see [DEC-006](../decisions/DEC-006.md)):
   - take `flock` on `$WORK_DIR/.lock` (warn and continue without it where `flock` is missing)
   - refuse if the depth is not 1, 2 or 3
   - count live recorded panes (`*.pane` compared with `tmux list-panes -a`, current pane excluded); refuse if the count plus this pane exceeds `CCORCH_MAX_PANES`
   - at depth 2 and 3, count live siblings with the same `CCORCH_PARENT_ID` (paired through `<id>.parent`); refuse if the count plus this pane exceeds `CCORCH_MAX_CHILDREN_D1` (depth 2) or `_D2` (depth 3)
   - write `<id>.pane` and `<id>.parent`, release the lock
   - a refusal writes `status: refused` with a `reason:` line to the result file and exits 1; the trap signals the parent
4. Set the pane title; write the status dashboard (depth 1); build the system prompt.
5. Build the `claude` argv: `--permission-mode auto`, `--disallowedTools` with one rule per element, `--append-system-prompt`.
6. Dry run: write the prompt to `$WORK_DIR/dry-run.system-prompt`, print `gate: ok` and the argv, exit 0. The trap writes `status: dry-run` and does not signal.
7. Write the task file, start the watchdog and the task delivery subshell, run `claude` interactively.
8. After `claude` exits: stop the watchdog, write a success result if none exists. The trap signals the parent.

## Tool Flags

| Flag | Value |
|------|-------|
| `--permission-mode` | `auto` at every depth |
| `--disallowedTools`, every depth | `Bash(rm -rf *)` `Bash(git push --force *)` `Bash(git push -f *)` `Bash(git reset --hard *)` `Bash(git clean *)` `Bash(sudo *)` |
| `--disallowedTools`, depth 2 and 3 | adds `Bash(git push *)` |
| `--disallowedTools`, depth 3 | adds `Agent` and `Bash(tmux *)` |
| `--append-system-prompt` | the generated prompt |

`--dangerously-skip-permissions` and `--allowedTools` are not passed: under the bypass, allow rules have no effect. The Bash deny rules cover the usual command form only and are not a security boundary; the boundaries are the auto-mode classifier and the start gate. Both pane-creation templates in the system prompt pass `CCORCH_MAX_PANES`, `CCORCH_MAX_CHILDREN_D1`, `CCORCH_MAX_CHILDREN_D2` and `CCORCH_PARENT_ID`, because a pane created by `tmux split-pane` gets its environment from the tmux server.

## Key Design Decisions

### trap EXIT for Signal Guarantee

The `trap cleanup EXIT` pattern ensures:
- Normal exit → signal sent
- Refusal → `status: refused` result written, signal sent
- Error exit → error result written + signal sent
- Kill signal → signal sent (EXIT trap fires on SIGTERM)
- Timeout kill → timeout result already written by watchdog + signal sent
- Dry run → `status: dry-run` result written; no signal

### Atomic Result File Write

All writes use the `write-to-tmp → mv` pattern:
- Prevents parent from reading a partially written file
- `mv` is atomic on same filesystem (`/tmp/`)

### Watchdog Process

Runs as a background subshell, started after the gate and the dry-run exit:
- Independent of the Claude Code process
- Kills the entire process group (`kill 0`) on timeout
- Writes timeout result before killing

### Child ID Generation

`depth${DEPTH}-$(date +%s%N | cut -c 11-16)` produces IDs like `depth2-483921`:
- Includes depth for debugging
- Nanosecond digits reduce collisions on fast sequential launches

## Tests

`tests/test_wrapper.sh` runs the wrapper with `CCORCH_DRY_RUN=1` against a fake `tmux` and `claude`; CI runs it in `.github/workflows/lint.yml`.
