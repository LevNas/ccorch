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
| `CCORCH_LOCK_WAIT` | Seconds to wait for the start lock, then refuse (default: 10) |
| `CCORCH_PARENT_ID` | The parent's child ID; required at depth 2 and 3, unset at depth 1 |
| `CCORCH_DRY_RUN` | If set: run the gate, print the `claude` argv, exit 0 without starting `claude` |

## Script Flow

1. Check `CCORCH_WORK_DIR` and `CCORCH_PARENT_CHANNEL`. If either is missing, no result file or signal is possible: print to stderr and exit 2. This is the only failure that does not go through a result file.
2. Resolve `WORK_DIR` and `PROJECT_DIR` to absolute paths against `$PWD` (before any `cd`), create `WORK_DIR` (not in a dry run), read the other variables without `:?`, and compute `CHILD_ID` and `RESULT_FILE`. In a dry run, `OUT_DIR` is a fresh `mktemp -d` printed on the first line (`out_dir: <path>`); otherwise `OUT_DIR` is `WORK_DIR`. Every write of the process (result file, `status.md`, `result.md`, prompt dump) goes to `OUT_DIR`.
3. Install `trap cleanup EXIT`. This comes before every check that can fail, so a missing task argument, a bad `PROJECT_DIR` or a bad number is a `status: refused` result with a signal, not a silent exit. The trap is the only EXIT trap: it starts with `set +e`, releases the lock, kills the watchdog, writes the fallback result, copies a Main Brain's result to `result.md` when that is absent, and signals the parent last. Every write in it is guarded, so a work directory that cannot be written does not stop the signal (a dry run does not signal). Front-matter values (`depth:`, `task:`, `reason:`) are sanitized to one line.
4. **Start gate** (see [DEC-006](../decisions/DEC-006.md)):
   - refuse if the task, `CCORCH_SESSION_ID` or `CCORCH_PROJECT_DIR` is missing, if `PROJECT_DIR` cannot be entered, if `CCORCH_TIMEOUT`, `CCORCH_MAX_PANES`, `CCORCH_MAX_CHILDREN_D1`, `CCORCH_MAX_CHILDREN_D2` or `CCORCH_LOCK_WAIT` is not a positive integer of at most 6 digits, or if the claimed depth is not 1, 2 or 3
   - take the `mkdir` lock `$WORK_DIR/.lock.d` (not in a dry run: it records nothing): bounded wait, then refuse; a lock left by a killed wrapper is removed by hand (the refusal names it). The holder writes its PID to `.lock.d/owner`; if that write fails the lock is removed and the start is refused. The wait is `CCORCH_LOCK_WAIT` seconds (default 10), tried every 0.1 s. A timeout is refused with a reason that names the lock directory and the owner pid, and says to remove the directory if no ccorch pane is running. Nothing else removes a lock, so `release_lock` clears its flag first and then removes the owner file and the directory
   - read the pane id with `tmux display-message -p -t "$TMUX_PANE"` (plain `display-message` only if `TMUX_PANE` is unset); refuse if it is empty or not in `tmux list-panes -a`, and refuse if that command fails
   - **derive the depth**: with no `CCORCH_PARENT_ID` the claimed depth must be 1 and no other live depth-1 record may exist in `$WORK_DIR`; with a parent, require its `<id>.pane` and `<id>.depth` records (depth 1 or 2) and a live parent pane, and refuse if `CCORCH_DEPTH` is not the parent's depth plus 1 (the reason names both). The effective depth drives the deny list, the children limit and the prompt
   - count live recorded panes (`*.pane` compared with the `list-panes` output, current pane excluded); refuse if the count plus this pane exceeds `CCORCH_MAX_PANES`
   - at depth 2 and 3, count live siblings with the same `CCORCH_PARENT_ID` (paired through `<id>.parent`); refuse if the count plus this pane exceeds `CCORCH_MAX_CHILDREN_D1` (depth 2) or `_D2` (depth 3)
   - write `<id>.pane`, `<id>.depth` and `<id>.parent` (not in a dry run), release the lock
   - a refusal writes `status: refused` with a `reason:` line to the result file and exits 1; the trap signals the parent
5. Set the pane title; write the status dashboard (depth 1); build the system prompt.
6. Build the `claude` argv: `--permission-mode auto`, `--disallowedTools` with one rule per element, `--append-system-prompt`.
7. Dry run: write the prompt to `$OUT_DIR/<id>.dry-run.system-prompt`, print `gate: ok` and the argv, exit 0. The trap writes `status: dry-run` into `OUT_DIR` and does not signal. The live `WORK_DIR` is only read: no lock, no records, no new files.
8. Write the task file, start the watchdog and the task delivery subshell, run `claude` interactively and keep its exit status.
9. After `claude` exits: stop the watchdog. If no result file exists, write `status: error` with the exit code when it was non-zero, and `status: incomplete` when it was 0 (never `success`). The trap signals the parent.

## Tool Flags

| Flag | Value |
|------|-------|
| `--permission-mode` | `auto` at every depth |
| `--disallowedTools`, every depth | `Bash(rm -rf *)` `Bash(rm -fr *)` `Bash(rm -Rf *)` `Bash(rm -r -f *)` `Bash(rm -f -r *)` `Bash(rm -r --force *)` `Bash(rm --recursive *)` `Bash(git push --force *)` `Bash(git push *--force*)` `Bash(git push -f *)` `Bash(git push * -f*)` `Bash(git push * +*)` `Bash(git push *--delete*)` `Bash(git push * :*)` `Bash(git branch -D *)` `Bash(git reset --hard *)` `Bash(git clean *)` `Bash(sudo *)` |
| `--disallowedTools`, depth 2 and 3 | adds `Bash(git push *)` and `Bash(git -C * push*)` |
| `--disallowedTools`, depth 3 | adds `Agent` and `Bash(tmux *)` |
| `--append-system-prompt` | the generated prompt |

`--dangerously-skip-permissions` and `--allowedTools` are not passed: under the bypass, allow rules have no effect. The Bash deny rules cover the common forms only and are not a security boundary (The rules are the common forms, not a closed list. Known gaps: other flag spellings and orderings, full paths (`/bin/rm`), `sh -c '...'`, aliases and wrapper scripts, and any command that reaches the same effect another way.); the boundaries are the auto-mode classifier and the start gate. Both pane-creation templates in the system prompt pass `CCORCH_MAX_PANES`, `CCORCH_MAX_CHILDREN_D1`, `CCORCH_MAX_CHILDREN_D2` and `CCORCH_PARENT_ID`, because a pane created by `tmux split-pane` gets its environment from the tmux server.

## Key Design Decisions

### trap EXIT for Signal Guarantee

The `trap cleanup EXIT` pattern ensures:
- Normal exit → signal sent
- Refusal → `status: refused` result written, lock released, signal sent
- Error exit → error result written + signal sent
- Kill signal → signal sent (EXIT trap fires on SIGTERM)
- Timeout kill → timeout result already written by watchdog + signal sent
- Dry run → `status: dry-run` result written; no signal

### Atomic Result File Write

The wrapper's own writes (refusal, error, incomplete, timeout results, the first `status.md`,
the copy to `result.md`) use the `write-to-tmp → mv` pattern:
- Prevents parent from reading a partially written file
- `mv` is atomic on same filesystem (`/tmp/`)

The panes do not. Their prompt tells them to write the result file and `status.md` with the
Write tool (or Edit), never with `mv` or shell redirection: a user's ask rule on those commands
(for example `Bash(mv *)`) overrides auto mode and stopped the pane in the 0.6.0 live check.
The Write tool is not atomic. An empty result file counts as no result (see below); a
partly written one could only be read if the pane were killed in the middle of the write.
The result file lives under `/tmp/ccorch/`, outside the pane's project directory; the
live check saw the Write tool allowed there in auto mode, but an ask rule on Write or Edit
would stop the pane the same way.

### Completion signal: the Stop hook and `result.md`

`hooks/stop_signal.sh` runs at the end of every turn of a pane (Claude Code's Stop event),
not only when the pane is done. Since 0.6.1 the two kinds of parent are treated differently:
- **The session's Main Brain** (`CCORCH_COPY_RESULT=1`) signals the user's session only once
  its result file (`CCORCH_RESULT_FILE`) exists and is non-empty, after copying it to
  `${WORK_DIR}/result.md`. Turns that end before that send nothing. Every later Stop copies
  again, so a rewritten result is followed while the Main Brain's session is still open.
  The user's session runs a shell loop, not a model, so it needs a signal that always
  comes with a result.
- **Children and grandchildren** signal their parent at every Stop, as before. Their parent
  is a model that is told to check for the child's result file and wait again when there
  is none. This keeps a stuck child visible: children are launched with the same
  `CCORCH_TIMEOUT` as their parent and start later, so the parent's own timeout would end
  it before a silent child's timeout could report.
- A pane started by an older wrapper has no `CCORCH_RESULT_FILE` and signals on every Stop.
- The wrapper's `cleanup()` copies the result to `result.md` when `result.md` is absent, or
  when this wrapper ran `claude` and the content differs from the result file (`cmp`, not
  mtime, so a rewrite within the same second is not missed). A wrapper refused before
  `claude` started never replaces an existing `result.md`, which may be another Main
  Brain's result. A result rewritten after the last Stop, or a refusal, error or
  timeout result, still reaches it. The hook and `cleanup()` stage the copy through
  per-process temporary names, so they cannot interleave.
- An empty result file counts as no result everywhere: the hook, the watchdog and
  `cleanup()` all test with `-s`.

Trade-off: a Main Brain that is stuck (a permission prompt, a classifier block, a question
to the user) and has written no result does not wake the user's session; that session hears
from it when the Main Brain's `CCORCH_TIMEOUT` runs out and the watchdog writes
`status: timeout`. Before 0.6.1 the session was woken at every turn but found no result to
read.

Dependency: a `tmux wait-for -S` on a channel nobody waits on is kept for the next
`wait-for` on that channel (checked on tmux 3.7b), so a child that finishes before its parent
starts waiting is not lost. The fake tmux in the tests cannot show this.

### Watchdog Process

Runs as a background subshell, started after the gate and the dry-run exit:
- Independent of the Claude Code process
- Kills the entire process group (`kill 0`) on timeout
- Writes timeout result before killing

### Child ID Generation

`depth${DEPTH}-$$-${RANDOM}` produces IDs like `depth2-48392-17011`:
- Includes depth for debugging
- PID and `$RANDOM` work on macOS, where BSD `date` has no `%N`. IDs must be unique: the gate pairs `<id>.pane` with `<id>.parent` and `<id>.depth`, and a shared ID would let panes overwrite each other's files

## Tests

`tests/test_wrapper.sh` runs the wrapper against a fake `tmux` and a fake `claude`, in both dry (`CCORCH_DRY_RUN=1`) and real (non-dry) cases; the real cases cover the records, the lock, signalling on refusal and a failing write, `$TMUX_PANE`, and claude's exit status. CI runs it in `.github/workflows/lint.yml`.
