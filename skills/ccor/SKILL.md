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
   bash ${SCRIPT_PATH} '${TASK}'"
```

Where `${TASK}` is the user's task description passed to `/ccor`.

**Important**: The Main Brain's system prompt (injected by the wrapper script) instructs it to:
- Analyze the task and decompose into subtasks
- Create child panes for independent subtasks
- Wait for children to complete
- Aggregate results into `${WORK_DIR}/result.md`
- Signal completion via `tmux wait-for -S ${CHANNEL}`

### 5. Background Completion Wait

Use `run_in_background: true` to wait for the Main Brain's completion signal without blocking the user's session:

```bash
# Run in background — user continues working
tmux wait-for "$CHANNEL"
```

After the signal is received, read and present the results:

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

If approved, close all completed panes:

```bash
for pane_file in ${WORK_DIR}/*.pane; do
  pane_id=$(cat "$pane_file")
  tmux kill-pane -t "$pane_id" 2>/dev/null || true
done
rm -f ${WORK_DIR}/*.pane
```

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
| `CCORCH_TIMEOUT` | `600` | Timeout in seconds per pane |
| `CCORCH_MAX_PANES` | `8` | Maximum total panes per session |
| `CCORCH_MAX_CHILDREN_D1` | `3` | Max concurrent children for Main Brain |
| `CCORCH_MAX_CHILDREN_D2` | `2` | Max concurrent grandchildren per Child |

## Error Handling

| Scenario | Behavior |
|----------|----------|
| Not in tmux | Error message, no action |
| Already orchestrating | Error message, no action |
| Main Brain timeout | Timeout result in result.md |
| Main Brain crash | Error result written by trap, signal still sent |
| Child/Grandchild failure | Partial results aggregated by Main Brain |

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
