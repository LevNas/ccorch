#!/bin/bash
# ccorch-wrapper.sh — Child pane launcher with signal guarantee
#
# Launches Claude Code in a child pane with:
# - trap EXIT for guaranteed signal delivery to parent
# - Timeout watchdog to prevent infinite execution
# - Atomic result file writes (tmp → mv)
# - Depth-based tool restrictions
#
# Usage:
#   CCORCH_DEPTH=1 CCORCH_SESSION_ID=... CCORCH_PARENT_CHANNEL=... \
#     CCORCH_WORK_DIR=... bash ccorch-wrapper.sh '<task description>'
#
# Required environment variables:
#   CCORCH_DEPTH          — Current depth (1, 2, or 3)
#   CCORCH_SESSION_ID     — Unique session identifier
#   CCORCH_PARENT_CHANNEL — tmux wait-for channel to signal parent
#   CCORCH_WORK_DIR       — Directory for result files
#
# Optional environment variables:
#   CCORCH_TIMEOUT        — Timeout in seconds (default: 600)
#   CCORCH_MAX_PANES      — Maximum pane count (default: 8)

set -euo pipefail

# --- Validate inputs ---

TASK="${1:?Usage: ccorch-wrapper.sh '<task description>'}"
DEPTH="${CCORCH_DEPTH:?CCORCH_DEPTH is required (1, 2, or 3)}"
SESSION_ID="${CCORCH_SESSION_ID:?CCORCH_SESSION_ID is required}"
PARENT_CHANNEL="${CCORCH_PARENT_CHANNEL:?CCORCH_PARENT_CHANNEL is required}"
WORK_DIR="${CCORCH_WORK_DIR:?CCORCH_WORK_DIR is required}"
TIMEOUT="${CCORCH_TIMEOUT:-600}"
MAX_PANES="${CCORCH_MAX_PANES:-8}"

# Resolve the directory where this script lives (for child pane references)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Generate unique child ID
CHILD_ID="depth${DEPTH}-$(date +%s%N | cut -c 11-16)"
RESULT_FILE="${WORK_DIR}/${CHILD_ID}.md"

# --- Signal guarantee via trap ---

cleanup() {
  # Write error result if no result file exists yet
  if [ ! -f "$RESULT_FILE" ]; then
    cat > "${RESULT_FILE}.tmp" <<EOF
---
status: error
depth: ${DEPTH}
task: "$(echo "$TASK" | head -c 100)"
completed: $(date -Iseconds)
---

# Error

Process terminated unexpectedly.
EOF
    mv "${RESULT_FILE}.tmp" "$RESULT_FILE"
  fi

  # Always signal parent
  tmux wait-for -S "$PARENT_CHANNEL" 2>/dev/null || true

  # Kill watchdog if still running
  if [ -n "${WATCHDOG_PID:-}" ]; then
    kill "$WATCHDOG_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# --- Timeout watchdog ---

(
  sleep "$TIMEOUT"
  # Only act if no result file yet (task still running)
  if [ ! -f "$RESULT_FILE" ]; then
    cat > "${RESULT_FILE}.tmp" <<EOF
---
status: timeout
depth: ${DEPTH}
task: "$(echo "$TASK" | head -c 100)"
completed: $(date -Iseconds)
---

# Timeout

Task exceeded ${TIMEOUT}s timeout limit.
EOF
    mv "${RESULT_FILE}.tmp" "$RESULT_FILE"
    # Kill the main process group
    kill 0 2>/dev/null || true
  fi
) &
WATCHDOG_PID=$!

# --- Build tool permissions based on depth ---

if [ "$DEPTH" -lt 3 ]; then
  ALLOWED_TOOLS="Read Edit Write Bash(git:status,git:diff,git:add,git:commit,tmux:*) Grep Glob Agent"
  DISALLOWED_OPTS=""
else
  ALLOWED_TOOLS="Read Edit Write Bash(git:status,git:diff,git:add,git:commit) Grep Glob"
  DISALLOWED_OPTS='--disallowedTools "Agent"'
fi

# --- Build system prompt ---

SYSTEM_PROMPT="You are a CCORCH worker at DEPTH=${DEPTH}.

## Environment
- Session ID: ${SESSION_ID}
- Work directory: ${WORK_DIR}
- Result file: ${RESULT_FILE}
- Parent channel: ${PARENT_CHANNEL}
- Timeout: ${TIMEOUT}s

## Rules
- Write your results to ${RESULT_FILE} when done
- No destructive git operations (push --force, reset --hard, branch -D)
- No destructive filesystem operations (rm -rf)
- Do not modify files outside the current working directory unless explicitly required by the task"

if [ "$DEPTH" -lt 3 ]; then
  NEXT_DEPTH=$((DEPTH + 1))
  SYSTEM_PROMPT="${SYSTEM_PROMPT}

## Creating Child Panes
You can delegate subtasks to child panes. To create one:

1. Generate a channel name: CHILD_CHANNEL=\"CCORCH_\${SESSION_ID}_child_\$(date +%s%N | cut -c 11-16)\"
2. Launch via tmux:
   tmux split-pane -h \"CCORCH_DEPTH=${NEXT_DEPTH} CCORCH_SESSION_ID=${SESSION_ID} CCORCH_PARENT_CHANNEL=\${CHILD_CHANNEL} CCORCH_WORK_DIR=${WORK_DIR} CCORCH_TIMEOUT=${TIMEOUT} bash ${SCRIPT_DIR}/ccorch-wrapper.sh '<subtask>'\"
3. Wait in background: run tmux wait-for \${CHILD_CHANNEL} with run_in_background: true
4. After signal, read the child's result file from ${WORK_DIR}/"
else
  SYSTEM_PROMPT="${SYSTEM_PROMPT}

## Depth Limit
You are at maximum depth (DEPTH=3). Do NOT attempt to create child panes.
Execute your assigned task directly and write results to ${RESULT_FILE}."
fi

SYSTEM_PROMPT="${SYSTEM_PROMPT}

## Result File Format
Write your results using this format:

\`\`\`markdown
---
status: success
depth: ${DEPTH}
task: \"Brief task description\"
completed: $(date -Iseconds)
---

# Results

## Execution Summary
What was done and the outcome.

## Changed Files
- path/to/file — description of change

## Discoveries
Any unexpected findings or important observations.
\`\`\`

Write to a temporary file first, then rename:
  cat > \"${RESULT_FILE}.tmp\" <<'RESULTEOF'
  ... content ...
  RESULTEOF
  mv \"${RESULT_FILE}.tmp\" \"${RESULT_FILE}\""

# --- Launch Claude Code ---

CLAUDE_CMD=(
  claude
  --dangerously-skip-permissions
  --allowedTools "$ALLOWED_TOOLS"
  --append-system-prompt "$SYSTEM_PROMPT"
  -p "$TASK"
)

if [ -n "${DISALLOWED_OPTS:-}" ]; then
  # Insert --disallowedTools before -p
  CLAUDE_CMD=(
    claude
    --dangerously-skip-permissions
    --allowedTools "$ALLOWED_TOOLS"
    --disallowedTools "Agent"
    --append-system-prompt "$SYSTEM_PROMPT"
    -p "$TASK"
  )
fi

"${CLAUDE_CMD[@]}"

# --- Post-execution ---

# Kill watchdog (task completed before timeout)
kill "$WATCHDOG_PID" 2>/dev/null || true
unset WATCHDOG_PID

# Write success result if Claude didn't write one
if [ ! -f "$RESULT_FILE" ]; then
  cat > "${RESULT_FILE}.tmp" <<EOF
---
status: success
depth: ${DEPTH}
task: "$(echo "$TASK" | head -c 100)"
completed: $(date -Iseconds)
---

# Results

Task completed successfully. Check Claude Code output for details.
EOF
  mv "${RESULT_FILE}.tmp" "$RESULT_FILE"
fi

# cleanup trap fires on exit → signals parent
