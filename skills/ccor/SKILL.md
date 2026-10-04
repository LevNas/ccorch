---
name: ccor
description: Orchestrate complex tasks across multiple tmux panes with 3-level depth control (Main Brain → Child → Grandchild). Launches a wrapper script in a new pane, waits for completion via tmux wait-for signal, and aggregates results from status/result markdown files.
license: MIT
allowed-tools: Bash, Read
---

# ccor

Orchestrate complex tasks across multiple tmux panes with 3-level depth control (Main Brain → Child → Grandchild).

## When to Use

- User invokes `/ccor` with a task description
- Task is complex enough to benefit from parallel decomposition
- Running inside a tmux session

## Procedure

### 1. Precondition Checks

Before launching orchestration, verify:

```bash
# Check tmux is available
command -v tmux >/dev/null 2>&1 || { echo "Error: tmux is required"; exit 1; }

# Check we're inside a tmux session
[ -n "$TMUX" ] || { echo "Error: Must run inside a tmux session"; exit 1; }

# Check we're not already inside an orchestration
[ -z "${CCORCH_DEPTH:-}" ] || { echo "Error: Already inside orchestration (DEPTH=$CCORCH_DEPTH)"; exit 1; }
```

If any check fails, inform the user and stop.

### 2. Initialize Session

```bash
SESSION_ID=$(date +%s)
WORK_DIR="/tmp/ccorch/${SESSION_ID}"
CHANNEL="CCORCH_DONE_${SESSION_ID}"
TIMEOUT="${CCORCH_TIMEOUT:-600}"
MAX_PANES="${CCORCH_MAX_PANES:-8}"
MAX_CHILDREN_D1="${CCORCH_MAX_CHILDREN_D1:-3}"
MAX_CHILDREN_D2="${CCORCH_MAX_CHILDREN_D2:-2}"

mkdir -p "$WORK_DIR"
```

### 3. Determine Wrapper Script Path

The wrapper script is located at `scripts/ccorch-wrapper.sh` relative to the plugin root.
Use `$CLAUDE_PLUGIN_ROOT` if available, otherwise resolve from the skill's location.

```bash
SCRIPT_PATH="${CLAUDE_PLUGIN_ROOT}/scripts/ccorch-wrapper.sh"
```

### 4. Launch Main Brain

Split the current pane and launch the wrapper script. Each pane gets a title with depth prefix for identification.

```bash
PROJECT_DIR=$(pwd)

tmux split-pane -h \
  "CCORCH_DEPTH=1 \
   CCORCH_SESSION_ID=${SESSION_ID} \
   CCORCH_PARENT_CHANNEL=${CHANNEL} \
   CCORCH_WORK_DIR=${WORK_DIR} \
   CCORCH_PROJECT_DIR=${PROJECT_DIR} \
   CCORCH_TIMEOUT=${TIMEOUT} \
   CCORCH_MAX_PANES=${MAX_PANES} \
   CCORCH_MAX_CHILDREN_D1=${MAX_CHILDREN_D1} \
   CCORCH_MAX_CHILDREN_D2=${MAX_CHILDREN_D2} \
   bash ${SCRIPT_PATH} '${TASK}'"
```

Where `${TASK}` is the user's task description passed to `/ccor`.

**Important**: The Main Brain's system prompt (injected by the wrapper script) instructs it to:
- Analyze the task and decompose into subtasks
- Create child panes for independent subtasks
- Wait for children to complete, then close their panes (not its own)
- Write its result file once, at the end, with the Write tool

The ccorch Stop hook does the rest. At the end of the first turn in which the Main Brain's
result file exists, it copies that file to `${WORK_DIR}/result.md` and signals `${CHANNEL}`.
Turns that end before the result file exists send no signal. (Children and grandchildren
signal their parent at every turn instead; the parent checks for their result file and
waits again.) The Main Brain's session stays
open after that; the wrapper finishes when the pane is closed or its `claude` exits, and
then copies the result again if it was rewritten. `CCORCH_TIMEOUT` does not close it: the
watchdog acts only on a pane that has written no result, so a finished Main Brain's pane
stays open until it is closed (step 7).

### 5. Background Completion Wait

Use `run_in_background: true` to wait for the Main Brain's completion signal without blocking the user's session.
Wait again until `result.md` exists, so an early signal (from a pane started by an older wrapper or hook) is not read as the result.
Shell variables do not carry over between Bash calls, so set the two values in the same command, with the literal session ID from step 2:

```bash
# Run in background — user continues working
WORK_DIR=/tmp/ccorch/<session_id>; CHANNEL=CCORCH_DONE_<session_id>
until [ -f "${WORK_DIR}/result.md" ]; do
  tmux wait-for "$CHANNEL" || { echo "tmux wait-for failed; see ${WORK_DIR}" >&2; exit 1; }
  [ -f "${WORK_DIR}/result.md" ] && break
  # A wrapper signals just before it exits: look for a live Main Brain pane for up to 10 s,
  # so a pane that is slow to close is not taken for a live one.
  alive=1
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    [ -f "${WORK_DIR}/result.md" ] && break 2
    live=$(tmux list-panes -a -F '#{pane_id}') || { echo "tmux list-panes failed; see ${WORK_DIR}" >&2; exit 1; }
    alive=""
    for f in "${WORK_DIR}"/depth1-*.pane; do
      [ -f "$f" ] && printf '%s\n' "$live" | grep -qxF -- "$(cat "$f")" && alive=1
    done
    [ -n "$alive" ] || break
  done
  [ -n "$alive" ] || { echo "No Main Brain pane is alive (or none was recorded) and there is no result.md; see ${WORK_DIR}" >&2; exit 1; }
done
```

A signal sent before the wait starts is not lost: tmux keeps it for the next `wait-for` on the channel.
If `tmux wait-for` fails (the tmux server is gone, or the channel name is empty), the loop stops instead of spinning; check `${WORK_DIR}` by hand.
If a signal comes, `result.md` is still missing and no Main Brain pane is alive within 10 seconds, the loop stops too.
That happens when the Main Brain ended and copying its result to `result.md` failed (an older `result.md` is then removed, so it is not read as this result), or when the Main Brain was refused before it recorded its pane.
A Main Brain pane that stays alive (for example, a second Main Brain was refused while the first runs) sends the loop back to waiting.
A Main Brain killed with SIGKILL does not end up here: tmux runs the pane's `pane-died` hook, which writes an error result and copies it to `result.md` before it signals.

After `result.md` exists, read and present the results:

```bash
cat "${WORK_DIR}/result.md"
```

### 6. Present Results

Read `${WORK_DIR}/status.md` (dashboard) and `${WORK_DIR}/result.md` and present a summary to the user:
- Overall status (success / partial / error)
- Agent overview from status dashboard (roles, owned paths, statuses)
- List of changed files
- Key discoveries

### 7. Pane Cleanup

After presenting results, ask the user: "Completed panes are still open. Close them?"

If approved, close all completed panes, the Main Brain's included. Closing the Main Brain's
pane ends its session; the wrapper then finishes and leaves its records:

```bash
for pane_file in ${WORK_DIR}/*.pane; do
  pane_id=$(cat "$pane_file")
  tmux kill-pane -t "$pane_id" 2>/dev/null || true
done
```

Leave the `.pane` files in place: the wrapper ignores dead panes, and deleting them would
need `rm`, which a user's ask rule may stop for approval.

Note: The Main Brain also performs pane cleanup for its children during orchestration.
This step handles any remaining panes (e.g., the Main Brain's own window).

## ccmemo Integration

If ccmemo is installed (check if `/record-knowledge` skill is available):

- After presenting results, suggest: "Use `/record-knowledge` to persist any important discoveries from this orchestration."
- If the task involved planning, mention: "Use `/plan-task` to track this work across sessions."

If ccmemo is not installed, skip these suggestions silently.

## Worktree Guidance

The Main Brain's system prompt includes guidance on `--worktree` usage:

> If the task involves code changes across multiple files that could conflict between children,
> use `--worktree` (`-w`) when launching Claude Code in child panes. For research, analysis,
> or documentation tasks, worktree is unnecessary.

Branch naming convention: `claude/<scope>-<session_id>` (e.g., `claude/auth-1711871234`).

This decision is delegated to the Main Brain based on task analysis.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CCORCH_TIMEOUT` | `600` | Timeout in seconds for a pane that has written no result |
| `CCORCH_MAX_PANES` | `8` | Maximum live ccorch panes per session, Main Brain included; your own pane is not counted |
| `CCORCH_MAX_CHILDREN_D1` | `3` | Max concurrent children for the Main Brain |
| `CCORCH_MAX_CHILDREN_D2` | `2` | Max concurrent grandchildren per Child |
| `CCORCH_PARENT_ID` | unset | Set by each pane for the panes it starts; required at depth 2 and 3 |
| `CCORCH_DRY_RUN` | unset | Run the start gate, print the `claude` arguments, start nothing |

The wrapper enforces the three limits before `claude` starts. A pane started over a limit
does not run: its result file has `status: refused` and a one-line reason, and the parent is
signalled as usual. Treat that as the child's result. The depth is not taken on trust: a
pane's depth must equal its recorded parent's depth plus 1, and a session has one Main Brain.
If a pane ends without a result file, the wrapper records `status: error` (with the exit
code) or `status: incomplete`, never `success`.

## Permissions

Panes start with `--permission-mode auto`, not with a permission bypass. Deny rules apply
at every depth (the usual forms of `rm -rf`, force push, hard reset, `git clean` and
`sudo`); depth 2 and 3 also deny `git push`, and depth 3 denies the Agent tool and `tmux`. The Bash deny rules catch
the usual command form only and are not a security boundary; the boundaries are the
auto-mode classifier and the start gate. The system prompt tells each pane
not to work around a denial (for example with `sh -c` or a full path): that is a rule
the pane must follow, not something the deny rules enforce.

In auto mode a classifier reviews actions. If it blocks one, the pane may stop and wait:
a human has to look at that pane and approve or redirect it. When a run is slow, tell the
user that a pane waiting on a blocked action is a likely reason.

## Error Handling

| Scenario | Behavior |
|----------|----------|
| Not in tmux | Error message, no action |
| Already orchestrating | Error message, no action |
| Main Brain waiting for a human (a permission prompt, a question) | No signal arrives until it writes its result or `CCORCH_TIMEOUT` runs out. If the user asks, or the wait is long, tell them to look at the Main Brain's pane |
| Main Brain refused, error, incomplete or timeout | The wrapper writes the Main Brain's result file when the Main Brain wrote none, and copies it to result.md; report its `status:` and reason (a refusal has `status: refused` and a reason) |
| Main Brain crash | Error result written by trap, signal still sent |
| Child/Grandchild failure | Partial results aggregated by Main Brain |
| Child over a pane or children limit | `status: refused` with the reason in its result file |

## Example

```
User: /ccor Refactor the auth module: extract JWT middleware, add unit tests, update OpenAPI spec

1. Session initialized: /tmp/ccorch/1711871234/
2. Main Brain launched in new tmux window
3. User's session returns to interactive mode

[... user continues other work ...]

4. Completion notification received
5. Results:
   - Child 1 (JWT middleware): SUCCESS — extracted to middleware/jwt.ts
   - Child 2 (unit tests): SUCCESS — 12 tests added
   - Child 3 (OpenAPI spec): SUCCESS — spec updated
   Overall: SUCCESS (3/3 children completed)
```
