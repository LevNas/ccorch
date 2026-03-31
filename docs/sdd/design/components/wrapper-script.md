# Component: Wrapper Script (`ccorch-wrapper.sh`)

## Purpose

Launches Claude Code in a child pane with proper environment setup, signal guarantee on exit, and timeout enforcement. This is the critical reliability component — it ensures the parent always receives a signal, even on crashes.

## Location

`scripts/ccorch-wrapper.sh`

## Interface

```bash
ccorch-wrapper.sh <task_description>
```

### Required Environment Variables

| Variable | Description |
|----------|-------------|
| `CCORCH_DEPTH` | Current depth (1, 2, or 3) |
| `CCORCH_SESSION_ID` | Session identifier |
| `CCORCH_PARENT_CHANNEL` | Channel to signal parent on completion |
| `CCORCH_WORK_DIR` | Directory for result files |
| `CCORCH_TIMEOUT` | Timeout in seconds (default: 600) |
| `CCORCH_MAX_PANES` | Maximum pane count (default: 8) |

## Script Flow

```bash
#!/bin/bash
set -euo pipefail

TASK="$1"
DEPTH="${CCORCH_DEPTH:?}"
SESSION_ID="${CCORCH_SESSION_ID:?}"
PARENT_CHANNEL="${CCORCH_PARENT_CHANNEL:?}"
WORK_DIR="${CCORCH_WORK_DIR:?}"
TIMEOUT="${CCORCH_TIMEOUT:-600}"
CHILD_ID="depth${DEPTH}-$(date +%s%N | tail -c 6)"
RESULT_FILE="${WORK_DIR}/${CHILD_ID}.md"

# --- Signal guarantee ---
cleanup() {
  if [ ! -f "$RESULT_FILE" ]; then
    cat > "${RESULT_FILE}.tmp" <<ERREOF
---
status: error
depth: ${DEPTH}
task: "${TASK:0:100}"
completed: $(date -Iseconds)
---

# Error

Process terminated unexpectedly.
ERREOF
    mv "${RESULT_FILE}.tmp" "$RESULT_FILE"
  fi
  tmux wait-for -S "$PARENT_CHANNEL" 2>/dev/null || true
}
trap cleanup EXIT

# --- Timeout watchdog ---
(
  sleep "$TIMEOUT"
  if [ ! -f "$RESULT_FILE" ]; then
    cat > "${RESULT_FILE}.tmp" <<TOEOF
---
status: timeout
depth: ${DEPTH}
task: "${TASK:0:100}"
completed: $(date -Iseconds)
---

# Timeout

Task exceeded ${TIMEOUT}s timeout.
TOEOF
    mv "${RESULT_FILE}.tmp" "$RESULT_FILE"
    # Kill the claude process in this pane
    kill 0 2>/dev/null || true
  fi
) &
WATCHDOG_PID=$!

# --- Build Claude Code command ---
ALLOWED_TOOLS="Read Edit Write Grep Glob"
DISALLOWED_TOOLS=""

if [ "$DEPTH" -lt 3 ]; then
  # DEPTH 1 and 2: allow Agent and tmux in Bash
  ALLOWED_TOOLS="$ALLOWED_TOOLS Bash(git:status,git:diff,git:add,git:commit,tmux:*) Agent"
else
  # DEPTH 3: no Agent, no tmux
  ALLOWED_TOOLS="$ALLOWED_TOOLS Bash(git:status,git:diff,git:add,git:commit)"
  DISALLOWED_TOOLS="Agent"
fi

SYSTEM_PROMPT="You are CCORCH worker at DEPTH=${DEPTH}.
Session: ${SESSION_ID}
Work dir: ${WORK_DIR}
Result file: ${RESULT_FILE}
Parent channel: ${PARENT_CHANNEL}

IMPORTANT RULES:
- Write your results to ${RESULT_FILE} using the result file format
- No destructive git operations (push --force, reset --hard, branch -D)
- No rm -rf or other destructive filesystem operations"

if [ "$DEPTH" -lt 3 ]; then
  SYSTEM_PROMPT="${SYSTEM_PROMPT}
- You can create child panes using: CCORCH_DEPTH=$((DEPTH+1)) CCORCH_SESSION_ID=${SESSION_ID} CCORCH_PARENT_CHANNEL=<your_channel> CCORCH_WORK_DIR=${WORK_DIR} bash scripts/ccorch-wrapper.sh '<subtask>'"
else
  SYSTEM_PROMPT="${SYSTEM_PROMPT}
- You are at maximum depth. Do NOT attempt to create child panes.
- Execute your assigned task directly."
fi

# --- Launch Claude Code ---
CMD="claude --dangerously-skip-permissions"
CMD="$CMD --allowedTools \"$ALLOWED_TOOLS\""
if [ -n "$DISALLOWED_TOOLS" ]; then
  CMD="$CMD --disallowedTools \"$DISALLOWED_TOOLS\""
fi
CMD="$CMD --append-system-prompt \"$SYSTEM_PROMPT\""
CMD="$CMD -p \"$TASK\""

eval "$CMD"

# --- Kill watchdog ---
kill $WATCHDOG_PID 2>/dev/null || true

# --- Write success result if claude didn't ---
if [ ! -f "$RESULT_FILE" ]; then
  cat > "${RESULT_FILE}.tmp" <<SUCEOF
---
status: success
depth: ${DEPTH}
task: "${TASK:0:100}"
completed: $(date -Iseconds)
---

# Results

Task completed. Check Claude Code output for details.
SUCEOF
  mv "${RESULT_FILE}.tmp" "$RESULT_FILE"
fi
# cleanup trap will fire and send signal
```

## Key Design Decisions

### trap EXIT for Signal Guarantee

The `trap cleanup EXIT` pattern ensures:
- Normal exit → signal sent
- Error exit → error result written + signal sent
- Kill signal → signal sent (EXIT trap fires on SIGTERM)
- Timeout kill → timeout result already written by watchdog + signal sent

### Atomic Result File Write

All writes use the `write-to-tmp → mv` pattern:
- Prevents parent from reading a partially written file
- `mv` is atomic on same filesystem (`/tmp/`)

### Watchdog Process

Runs as a background subshell:
- Independent of the Claude Code process
- Kills the entire process group (`kill 0`) on timeout
- Writes timeout result before killing

### Child ID Generation

`depth${DEPTH}-$(date +%s%N | tail -c 6)` produces IDs like `depth2-483921`:
- Includes depth for debugging
- Nanosecond suffix prevents collisions on fast sequential launches
