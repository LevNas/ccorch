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
#   CCORCH_MAX_CHILDREN_D1 — Max children for Main Brain/DEPTH=1 (default: 3)
#   CCORCH_MAX_CHILDREN_D2 — Max children for Child/DEPTH=2 (default: 2)

set -euo pipefail

# --- Validate inputs ---

TASK="${1:?Usage: ccorch-wrapper.sh '<task description>'}"
DEPTH="${CCORCH_DEPTH:?CCORCH_DEPTH is required (1, 2, or 3)}"
SESSION_ID="${CCORCH_SESSION_ID:?CCORCH_SESSION_ID is required}"
PARENT_CHANNEL="${CCORCH_PARENT_CHANNEL:?CCORCH_PARENT_CHANNEL is required}"
WORK_DIR="${CCORCH_WORK_DIR:?CCORCH_WORK_DIR is required}"
TIMEOUT="${CCORCH_TIMEOUT:-600}"
MAX_PANES="${CCORCH_MAX_PANES:-8}"
MAX_CHILDREN_D1="${CCORCH_MAX_CHILDREN_D1:-3}"
MAX_CHILDREN_D2="${CCORCH_MAX_CHILDREN_D2:-2}"

# Resolve the directory where this script lives (for child pane references)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Generate unique child ID
CHILD_ID="depth${DEPTH}-$(date +%s%N | cut -c 11-16)"
RESULT_FILE="${WORK_DIR}/${CHILD_ID}.md"

# --- Record pane ID for cleanup ---

PANE_ID_FILE="${WORK_DIR}/${CHILD_ID}.pane"
tmux display-message -p '#{pane_id}' > "$PANE_ID_FILE" 2>/dev/null || true

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

# --- Status dashboard ---

STATUS_FILE="${WORK_DIR}/status.md"

# Initialize status dashboard for Main Brain
if [ "$DEPTH" -eq 1 ]; then
  cat > "${STATUS_FILE}.tmp" <<EOF
# Orchestration Status

**Task**: $(echo "$TASK" | head -c 200)
**Started**: $(date -Iseconds)
**Status**: running

## Agents

| ID | Role | Owned Paths | Status | Notes |
|----|------|-------------|--------|-------|
| main | Main Brain (coordinator) | — | running | Analyzing task |
EOF
  mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
fi

# --- Build system prompt ---

SYSTEM_PROMPT="You are a CCORCH worker at DEPTH=${DEPTH}.

## Environment
- Session ID: ${SESSION_ID}
- Work directory: ${WORK_DIR}
- Result file: ${RESULT_FILE}
- Status dashboard: ${STATUS_FILE}
- Parent channel: ${PARENT_CHANNEL}
- Timeout: ${TIMEOUT}s

## Rules
- Write your results to ${RESULT_FILE} when done
- No destructive git operations (push --force, reset --hard, branch -D)
- No destructive filesystem operations (rm -rf)
- Do not modify files outside the current working directory unless explicitly required by the task"

if [ "$DEPTH" -eq 1 ]; then
  NEXT_DEPTH=2
  SYSTEM_PROMPT="${SYSTEM_PROMPT}

## Status Dashboard
You MUST maintain ${STATUS_FILE} as a human-readable dashboard throughout the orchestration.
Update it when: creating children, a child completes, or the overall task finishes.

Format:
\`\`\`markdown
# Orchestration Status

**Task**: <overall task description>
**Started**: <timestamp>
**Status**: running | completed | partial | error

## Agents

| ID | Role | Owned Paths | Status | Notes |
|----|------|-------------|--------|-------|
| main | Main Brain (coordinator) | — | running | |
| child-1 | <role> | src/auth/ | running | |
| child-2 | <role> | tests/ | waiting | |
\`\`\`

Write atomically: cat > \"${STATUS_FILE}.tmp\" ... && mv \"${STATUS_FILE}.tmp\" \"${STATUS_FILE}\"

## Task Delegation Criteria
- Only delegate subtasks estimated at **10+ minutes** of work
- Tasks under 10 minutes: execute directly rather than paying the overhead of pane creation
- Ideal candidates: independent work on separate directories with minimal file overlap

## Child Pane Limits
- You may create at most **${MAX_CHILDREN_D1} child panes** concurrently
- More panes does NOT mean faster — host memory and disk I/O become bottlenecks, making ALL panes slower
- If you have more subtasks than the limit, run them in batches: launch ${MAX_CHILDREN_D1}, wait for completion, then launch the next batch
- Check current pane count: \`ls ${WORK_DIR}/*.pane 2>/dev/null | wc -l\`

## File Ownership
When delegating subtasks, assign **directory-level ownership** to each child:
- Each child should own distinct directories (e.g., child-1 owns \`src/auth/\`, child-2 owns \`tests/\`)
- Shared files (package.json, tsconfig.json, etc.) must NOT be modified by children — handle them yourself after children complete
- Declare ownership in the status dashboard and in each child's task description

## Creating Child Panes
To delegate a subtask:

1. Generate a channel name: CHILD_CHANNEL=\"CCORCH_\${SESSION_ID}_child_\$(date +%s%N | cut -c 11-16)\"
2. Launch via tmux:
   tmux split-pane -h \"CCORCH_DEPTH=${NEXT_DEPTH} CCORCH_SESSION_ID=${SESSION_ID} CCORCH_PARENT_CHANNEL=\${CHILD_CHANNEL} CCORCH_WORK_DIR=${WORK_DIR} CCORCH_TIMEOUT=${TIMEOUT} bash ${SCRIPT_DIR}/ccorch-wrapper.sh '<subtask>'\"
3. Wait in background: run tmux wait-for \${CHILD_CHANNEL} with run_in_background: true
4. After signal, read the child's result file from ${WORK_DIR}/
5. Update the status dashboard with the child's result

## Worktree Usage
If the task involves code changes that could conflict between children:
- Use \`--worktree\` (\`-w\`) when launching Claude Code in child panes
- Branch naming convention: \`claude/<scope>-${SESSION_ID}\` (e.g., \`claude/auth-${SESSION_ID}\`, \`claude/tests-${SESSION_ID}\`)
- For research, analysis, or documentation tasks, worktree is unnecessary

## Pane Cleanup
After all children have completed and results are aggregated:
1. List completed panes: \`ls ${WORK_DIR}/*.pane\`
2. Close each pane: \`tmux kill-pane -t <pane_id>\` (read pane ID from .pane files)
3. Clean up pane ID files: \`rm ${WORK_DIR}/*.pane\`
4. Update the status dashboard to reflect cleanup"

elif [ "$DEPTH" -eq 2 ]; then
  NEXT_DEPTH=3
  SYSTEM_PROMPT="${SYSTEM_PROMPT}

## File Ownership
You have been assigned specific directories to work on. Do NOT modify files outside your assigned scope.
If you need changes to shared files (package.json, etc.), note them in your result file for the Main Brain to handle.

## Child Pane Limits
- You may create at most **${MAX_CHILDREN_D2} grandchild panes** concurrently
- More panes does NOT mean faster — host resources become the bottleneck
- If you have more subtasks, run them in batches

## Creating Child Panes
You can further delegate subtasks to grandchild panes (DEPTH=3, max depth). To create one:

1. Generate a channel name: CHILD_CHANNEL=\"CCORCH_\${SESSION_ID}_child_\$(date +%s%N | cut -c 11-16)\"
2. Launch via tmux:
   tmux split-pane -h \"CCORCH_DEPTH=${NEXT_DEPTH} CCORCH_SESSION_ID=${SESSION_ID} CCORCH_PARENT_CHANNEL=\${CHILD_CHANNEL} CCORCH_WORK_DIR=${WORK_DIR} CCORCH_TIMEOUT=${TIMEOUT} bash ${SCRIPT_DIR}/ccorch-wrapper.sh '<subtask>'\"
3. Wait in background: run tmux wait-for \${CHILD_CHANNEL} with run_in_background: true
4. After signal, read the child's result file from ${WORK_DIR}/

## Pane Cleanup
After grandchildren complete, close their panes:
1. Read pane ID from .pane files: \`cat ${WORK_DIR}/<grandchild_id>.pane\`
2. Close: \`tmux kill-pane -t <pane_id>\`"

else
  SYSTEM_PROMPT="${SYSTEM_PROMPT}

## Depth Limit
You are at maximum depth (DEPTH=3). Do NOT attempt to create child panes.
Execute your assigned task directly and write results to ${RESULT_FILE}.

## File Ownership
You have been assigned specific directories to work on. Do NOT modify files outside your assigned scope.
If you need changes to shared files, note them in your result file for your parent to handle."
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
