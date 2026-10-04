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
6. Build the `claude` argv: `--add-dir` with `OUT_DIR`, `--permission-mode auto`, `--disallowedTools` with one rule per element, `--append-system-prompt`.
7. Dry run: write the prompt to `$OUT_DIR/<id>.dry-run.system-prompt`, print `gate: ok` and the argv, exit 0. The trap writes `status: dry-run` into `OUT_DIR` and does not signal. The live `WORK_DIR` is only read: no lock, no records, no new files.
8. Arm the pane's `pane-died` hook (see "Signal on SIGKILL, from tmux"). Write the task file, start the watchdog and the task delivery subshell, run `claude` interactively and keep its exit status.
9. After `claude` exits: stop the watchdog. If no result file exists, write `status: error` with the exit code when it was non-zero, and `status: incomplete` when it was 0 (never `success`). The trap signals the parent.

## Tool Flags

| Flag | Value |
|------|-------|
| `--add-dir` | `OUT_DIR` (the session directory; a temporary directory in a dry run) at every depth, so the file tools can read and write `status.md` and result files outside the project; placed before the other flags because it takes several paths |
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
- Kill signal → signal sent (EXIT trap fires on SIGTERM; `kill-pane` sends SIGHUP, which does the same)
- Timeout kill → timeout result already written by watchdog + signal sent
- Dry run → `status: dry-run` result written; no signal
- SIGKILL → no trap; tmux writes the result and signals instead (next section)

### Signal on SIGKILL, from tmux (0.6.3)

A wrapper killed with SIGKILL runs no trap, so before 0.6.3 its parent got no result and no
signal and waited until its own `CCORCH_TIMEOUT` (the user's session, for a Main Brain, waited
for ever). Before `claude` starts, outside a dry run, the wrapper now sets on its own pane:
- `remain-on-exit on`, so the pane outlives its program, and
- a pane-level `pane-died` hook: `run-shell 'bash scripts/ccorch-pane-died.sh <result file>
  <work dir> <copy_result> <depth>' ; wait-for -S <parent channel> ; kill-pane -t <pane>`.

`scripts/ccorch-pane-died.sh` writes `status: error` unless the pane left a result (through
`publish_if_absent`, below) and, for the Main Brain, copies the result to `result.md` when that
is absent or differs (the rule `cleanup()` uses after `claude` ran), removing an older
`result.md` if the copy fails. `run-shell` without `-b` finishes before the next command, so the parent is
signalled after the result is in place; the parent's wait loop then finds a result and
stops. The judgment "the pane is gone and left no result" is the same every time, so a script
makes it, not the parents' prompts.

- `pane-exited` would not work: a pane-level hook goes away with the pane before it runs. A
  server-level (`-g`) hook would work but changes the user's tmux configuration.
- `cleanup()` disarms both first, so a normal exit still signals once, from the trap. The
  option is unset first and the hook only if that worked: remain-on-exit left on without the
  hook would keep a dead pane in the user's tmux, while a hook left with the option off
  never runs. If the option stays, the hook closes the pane and signals once more.
- The channel, pane id and paths go into a tmux command string, so each must be plain: a
  channel of `[A-Za-z0-9_-]` not starting with `-`, a pane id of `%` and digits, absolute
  paths of `[A-Za-z0-9_./-]`. Otherwise no hook is set and the wrapper behaves as before
  0.6.3. If the hook cannot be set, the option is taken back at once.
- The wrapper sets the pane-level `remain-on-exit` and `pane-died` and later unsets them. A
  pane-level value the user had set on that pane is lost, and while the wrapper runs the
  pane-level `on` hides a window-level setting such as `failed`.
- The pane's program must be the wrapper's `bash` itself: the parent starts it with
  `tmux split-pane "ENV=... bash ccorch-wrapper.sh '<task>'"`, and the shell tmux starts
  (`default-shell`) must exec that simple command. `tests/test_tmux_hook.sh` checks this
  under the user's shell and `/bin/sh` (here zsh, and bash as `/bin/sh`); other shells are
  not checked.
- Checked only on tmux 3.7b, with a private tmux server and a fake `claude`
  (`tests/test_tmux_hook.sh`); not with a real Claude pane, and not on older tmux.
- Not covered: a SIGKILL before the hook is set (during the gate, or between arming it and
  starting `claude`), a SIGKILL during `cleanup()` after the hook is removed and before the
  trap's result and signal, and `kill-pane`, which runs no hook but makes the trap signal.
- `/ccor`'s safety exit matches pane ids from `depth1-*.pane`; after a tmux server restart a
  stale file could match a reused pane id and the loop would keep waiting. Not handled.

### Atomic Result File Write

The wrapper's own writes (refusal, error, incomplete results, the first `status.md`, the copy
to `result.md`) use the `write-to-tmp → mv` pattern:
- Prevents parent from reading a partially written file
- `mv` is atomic on same filesystem (`/tmp/`)

The two writes that can race with a pane still running, the watchdog's `status: timeout` and
`ccorch-pane-died.sh`'s `status: error`, go through `publish_if_absent` in
`scripts/ccorch-lib.sh` instead: `ln tmp target` fails atomically when the pane's result
exists, so a non-empty result is never overwritten (before 0.6.3 the watchdog tested `-s` and
then `mv`ed over the file). Without hard links (`ln` fails and the target does not exist) it
falls back to `mv -n`. An empty target counts as no result but may be a write in progress: it
is replaced only if still empty after `CCORCH_PUBLISH_GRACE` seconds (default 5). That
replacement is a check and then a `mv`, so a write in the instant between them is lost.

The panes do not. Their prompt tells them to write the result file and `status.md` with the
Write tool (or Edit), never with `mv` or shell redirection: a user's ask rule on those commands
(for example `Bash(mv *)`) overrides auto mode and stopped the pane in the 0.6.0 live check.
The Write tool is not atomic. An empty result file counts as no result (see below); a
partly written one could only be read if the pane were killed in the middle of the write.
The result file lives under `/tmp/ccorch/`, outside the pane's project directory. The
0.6.0 live check saw a child's Write allowed there in auto mode; in the 0.6.1 live check a
Read there asked for approval, so 0.6.2 passes the directory with `--add-dir`, and the
0.6.2 live check saw Read and Write there with no prompt. An ask rule on Write or Edit
would still stop the pane the same way.

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
- Since 0.6.3 the Main Brain does not signal when its copy to `result.md` fails, so the user's
  session never reads a missing or older `result.md` as this result. A later Stop copies
  again. If `cleanup()`'s own copy fails, it removes an older `result.md` that differs from
  the result file; `/ccor`'s wait loop then stops when no Main Brain pane is alive.
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
- Writes the timeout result with `publish_if_absent`, and kills the entire process group
  (`kill 0`) unless the pane's own result is there: when the timeout result was published,
  when it was written but could not be put in place (`publish_if_absent` returns 2), and when
  it could not even be written and the pane still has no result. A pane whose result came
  first keeps it and is not killed.

### Child ID Generation

`depth${DEPTH}-$$-${RANDOM}` produces IDs like `depth2-48392-17011`:
- Includes depth for debugging
- PID and `$RANDOM` work on macOS, where BSD `date` has no `%N`. IDs must be unique: the gate pairs `<id>.pane` with `<id>.parent` and `<id>.depth`, and a shared ID would let panes overwrite each other's files

## Tests

`tests/test_wrapper.sh` runs the wrapper against a fake `tmux` and a fake `claude`, in both dry (`CCORCH_DRY_RUN=1`) and real (non-dry) cases; the real cases cover the records, the lock, signalling on refusal and a failing write, `$TMUX_PANE`, and claude's exit status. Since 0.6.3 it also covers the hook's arming and disarming (from the fake tmux's log), the watchdog, the Stop hook and `cleanup()` with a failing copy (a fake `cp`), `publish_if_absent` and `ccorch-pane-died.sh` on their own. CI runs it in `.github/workflows/lint.yml`.

`tests/test_tmux_hook.sh` runs the wrapper in a private tmux server (`tmux -S <temp socket>`) with a fake `claude`: SIGKILL of the wrapper alone gives `status: error`, a signal and a closed pane, and a normal exit gives one signal and no dead pane. It is skipped without tmux. The race between the watchdog and a late write is closed by `ln` in `publish_if_absent`, not caught by a test: the tests show that `publish_if_absent` never replaces a result that exists.
