#!/bin/bash
# ccorch-wrapper.sh — Child pane launcher with signal guarantee
#
# Launches Claude Code in a child pane with:
# - trap EXIT for guaranteed signal delivery to parent
# - Timeout watchdog to prevent infinite execution
# - Atomic result file writes (tmp → mv)
# - Start gate: refuses to start when the depth, pane or children limits would be exceeded
# - Depth-based deny rules; children run in auto mode
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
#   CCORCH_PROJECT_DIR    — Project directory where Claude should run (user's cwd when /ccor was invoked)
#
# Optional environment variables:
#   CCORCH_TIMEOUT        — Timeout in seconds (default: 600)
#   CCORCH_MAX_PANES      — Maximum live ccorch panes, Main Brain included (default: 8)
#   CCORCH_MAX_CHILDREN_D1 — Max children for Main Brain/DEPTH=1 (default: 3)
#   CCORCH_MAX_CHILDREN_D2 — Max children for Child/DEPTH=2 (default: 2)
#   CCORCH_PARENT_PANE    — Parent's tmux pane ID (reserved for future layout use)
#   CCORCH_PARENT_ID      — Parent's child ID; required at depth 2 and 3, unset at depth 1
#   CCORCH_DRY_RUN        — If set, run the start gate, print the claude argv, and exit
#                           without starting claude

set -euo pipefail

# --- Validate inputs ---

TASK="${1:?Usage: ccorch-wrapper.sh '<task description>'}"
DEPTH="${CCORCH_DEPTH:?CCORCH_DEPTH is required (1, 2, or 3)}"
SESSION_ID="${CCORCH_SESSION_ID:?CCORCH_SESSION_ID is required}"
PARENT_CHANNEL="${CCORCH_PARENT_CHANNEL:?CCORCH_PARENT_CHANNEL is required}"
WORK_DIR="${CCORCH_WORK_DIR:?CCORCH_WORK_DIR is required}"
PROJECT_DIR="${CCORCH_PROJECT_DIR:?CCORCH_PROJECT_DIR is required}"
TIMEOUT="${CCORCH_TIMEOUT:-600}"
MAX_PANES="${CCORCH_MAX_PANES:-8}"
MAX_CHILDREN_D1="${CCORCH_MAX_CHILDREN_D1:-3}"
MAX_CHILDREN_D2="${CCORCH_MAX_CHILDREN_D2:-2}"

# Resolve the directory where this script lives (for child pane references)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Change to the user's project directory — all agents must run in the same context
cd "$PROJECT_DIR" || { echo "Error: Cannot cd to $PROJECT_DIR"; exit 1; }

# Generate unique child ID. PID and $RANDOM, not date +%N: BSD date has no %N, and a
# shared ID would make panes overwrite each other's .pane/.parent files and defeat the gate.
CHILD_ID="depth${DEPTH}-$$-${RANDOM}"
RESULT_FILE="${WORK_DIR}/${CHILD_ID}.md"
PANE_ID_FILE="${WORK_DIR}/${CHILD_ID}.pane"
PARENT_ID_FILE="${WORK_DIR}/${CHILD_ID}.parent"
PARENT_ID="${CCORCH_PARENT_ID:-}"
DRY_RUN="${CCORCH_DRY_RUN:-}"

# --- Signal guarantee via trap ---
# The trap must exist before the start gate so that a refusal reaches the parent.

cleanup() {
  # Write a result if none exists yet: dry-run for a dry run, error otherwise
  if [ ! -f "$RESULT_FILE" ]; then
    local fallback_status="error" fallback_title="Error" fallback_body="Process terminated unexpectedly."
    if [ -n "$DRY_RUN" ]; then
      fallback_status="dry-run"
      fallback_title="Dry run"
      fallback_body="CCORCH_DRY_RUN was set; claude was not started."
    fi
    cat > "${RESULT_FILE}.tmp" <<EOF
---
status: ${fallback_status}
depth: ${DEPTH}
task: "$(echo "$TASK" | head -c 100)"
completed: $(date -Iseconds)
---

# ${fallback_title}

${fallback_body}
EOF
    mv "${RESULT_FILE}.tmp" "$RESULT_FILE"
  fi

  # Always signal parent (a dry run must not touch a live channel)
  if [ -z "$DRY_RUN" ]; then
    tmux wait-for -S "$PARENT_CHANNEL" 2>/dev/null || true
  fi

  # Kill watchdog if still running
  if [ -n "${WATCHDOG_PID:-}" ]; then
    kill "$WATCHDOG_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# --- Start gate ---
# Computed refusal before claude starts: the depth must be 1-3, the live ccorch
# panes must stay within MAX_PANES, and the live siblings under one parent must
# stay within the per-depth children limit. Limits are enforced here, not by
# prompt text.

refuse() {
  local reason="$1"
  cat > "${RESULT_FILE}.tmp" <<EOF
---
status: refused
depth: ${DEPTH}
reason: "${reason}"
task: "$(echo "$TASK" | head -c 100)"
completed: $(date -Iseconds)
---

# Refused

${reason}
EOF
  mv "${RESULT_FILE}.tmp" "$RESULT_FILE"
  echo "ccorch: refused: ${reason}" >&2
  if [ -n "$DRY_RUN" ]; then
    echo "gate: refused: ${reason}"
  fi
  exit 1
}

CURRENT_PANE_ID=$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)

# Hold the lock from counting until the .pane/.parent files are written, so that
# simultaneous starts cannot both pass. flock is from util-linux and is not on
# macOS; without it the gate still runs, only without the lock.
# fd 9 is closed again before any subshell or claude starts, so none inherits it.
LOCKED=""
if command -v flock >/dev/null 2>&1; then
  mkdir -p "$WORK_DIR"
  exec 9>"${WORK_DIR}/.lock"
  flock 9
  LOCKED=1
else
  echo "ccorch: warning: flock not found; the start gate runs without a lock" >&2
fi

case "$DEPTH" in
  1|2|3) ;;
  *) refuse "CCORCH_DEPTH must be 1, 2 or 3 (got '${DEPTH}')" ;;
esac

LIVE_PANES=$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null || true)

LIVE_COUNT=0
SIBLING_COUNT=0
for pane_file in "${WORK_DIR}"/*.pane; do
  [ -e "$pane_file" ] || continue
  recorded_id=$(cat "$pane_file" 2>/dev/null || true)
  [ -n "$recorded_id" ] || continue
  [ "$recorded_id" != "$CURRENT_PANE_ID" ] || continue
  printf '%s\n' "$LIVE_PANES" | grep -qxF -- "$recorded_id" || continue
  LIVE_COUNT=$((LIVE_COUNT + 1))
  stem="${pane_file%.pane}"
  if [ -n "$PARENT_ID" ] && [ -f "${stem}.parent" ] \
     && [ "$(cat "${stem}.parent")" = "$PARENT_ID" ]; then
    SIBLING_COUNT=$((SIBLING_COUNT + 1))
  fi
done

if [ $((LIVE_COUNT + 1)) -gt "$MAX_PANES" ]; then
  refuse "pane limit reached: ${LIVE_COUNT} live ccorch panes, CCORCH_MAX_PANES=${MAX_PANES}"
fi

# The limit follows this pane's own depth; depth 1 (the Main Brain) has no parent.
if [ "$DEPTH" -ge 2 ]; then
  if [ "$DEPTH" -eq 2 ]; then CHILD_LIMIT="$MAX_CHILDREN_D1"; LIMIT_NAME="CCORCH_MAX_CHILDREN_D1"
  else CHILD_LIMIT="$MAX_CHILDREN_D2"; LIMIT_NAME="CCORCH_MAX_CHILDREN_D2"; fi
  if [ -z "$PARENT_ID" ]; then
    refuse "CCORCH_PARENT_ID is required at depth ${DEPTH}"
  fi
  if [ $((SIBLING_COUNT + 1)) -gt "$CHILD_LIMIT" ]; then
    refuse "children limit reached: ${SIBLING_COUNT} live siblings under ${PARENT_ID}, ${LIMIT_NAME}=${CHILD_LIMIT}"
  fi
fi

echo "$CURRENT_PANE_ID" > "$PANE_ID_FILE"
if [ -n "$PARENT_ID" ]; then
  echo "$PARENT_ID" > "$PARENT_ID_FILE"
fi

if [ -n "$LOCKED" ]; then
  flock -u 9
  exec 9>&-
fi

# Set descriptive pane title based on depth
if [ -z "$DRY_RUN" ]; then
  TASK_SHORT="$(echo "$TASK" | head -c 40 | tr '\n' ' ')"
  case "$DEPTH" in
    1) PANE_TITLE="[Main] ${TASK_SHORT}" ;;
    2) PANE_TITLE="[Child] ${TASK_SHORT}" ;;
    3) PANE_TITLE="[GChild] ${TASK_SHORT}" ;;
  esac
  tmux select-pane -t "$CURRENT_PANE_ID" -T "$PANE_TITLE" 2>/dev/null || true
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
- Do not modify files outside the current working directory unless explicitly required by the task

## Permissions
- This pane runs in auto mode. An action the auto-mode classifier blocks may need a human to approve it in this pane; if you are blocked, say so in your result file instead of retrying another way round
- Some commands are denied by rule at this depth. Treat a denial as final"

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
- At most **${MAX_PANES} live ccorch panes** in total, yourself included
- The wrapper enforces both limits: a child started over a limit does not run and returns \`status: refused\` with the reason in its result file. Treat that as the child's result, not as an error to work around
- Children run at DEPTH=2, may create at most ${MAX_CHILDREN_D2} grandchildren each, and cannot push (\`git push\` is denied below the Main Brain)
- More panes does NOT mean faster — host memory and disk I/O become bottlenecks, making ALL panes slower
- If you have more subtasks than the limit, run them in batches: launch ${MAX_CHILDREN_D1}, wait for completion, then launch the next batch
- The wrapper counts only live panes, so closing a finished child's pane frees its slot

## File Ownership
When delegating subtasks, assign **directory-level ownership** to each child:
- Each child should own distinct directories (e.g., child-1 owns \`src/auth/\`, child-2 owns \`tests/\`)
- Shared files (package.json, tsconfig.json, etc.) must NOT be modified by children — handle them yourself after children complete
- Declare ownership in the status dashboard and in each child's task description

## Creating Child Panes
To delegate a subtask:

1. Generate a channel name: CHILD_CHANNEL=\"CCORCH_\${SESSION_ID}_child_\$(date +%s%N | cut -c 11-16)\"
2. Launch via tmux:
   tmux split-pane -h \"CCORCH_DEPTH=${NEXT_DEPTH} CCORCH_SESSION_ID=${SESSION_ID} CCORCH_PARENT_CHANNEL=\${CHILD_CHANNEL} CCORCH_WORK_DIR=${WORK_DIR} CCORCH_PROJECT_DIR=${PROJECT_DIR} CCORCH_TIMEOUT=${TIMEOUT} CCORCH_MAX_PANES=${MAX_PANES} CCORCH_MAX_CHILDREN_D1=${MAX_CHILDREN_D1} CCORCH_MAX_CHILDREN_D2=${MAX_CHILDREN_D2} CCORCH_PARENT_ID=${CHILD_ID} bash ${SCRIPT_DIR}/ccorch-wrapper.sh '<subtask>'\"
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
3. Leave the \`.pane\` files in place (the wrapper ignores dead panes, and your own record is among them)
4. Update the status dashboard to reflect cleanup"

elif [ "$DEPTH" -eq 2 ]; then
  NEXT_DEPTH=3
  SYSTEM_PROMPT="${SYSTEM_PROMPT}

## File Ownership
You have been assigned specific directories to work on. Do NOT modify files outside your assigned scope.
If you need changes to shared files (package.json, etc.), note them in your result file for the Main Brain to handle.

## Child Pane Limits
- You may create at most **${MAX_CHILDREN_D2} grandchild panes** concurrently
- At most **${MAX_PANES} live ccorch panes** in total
- The wrapper enforces both limits: a grandchild started over a limit returns \`status: refused\` with the reason in its result file
- \`git push\` is denied for you; only the Main Brain pushes
- More panes does NOT mean faster — host resources become the bottleneck
- If you have more subtasks, run them in batches

## Creating Grandchild Panes
You can further delegate subtasks to grandchild panes (DEPTH=3, max depth). To create one:

1. Generate a channel name: CHILD_CHANNEL=\"CCORCH_\${SESSION_ID}_child_\$(date +%s%N | cut -c 11-16)\"
2. Launch via tmux:
   tmux split-pane -h \"CCORCH_DEPTH=${NEXT_DEPTH} CCORCH_SESSION_ID=${SESSION_ID} CCORCH_PARENT_CHANNEL=\${CHILD_CHANNEL} CCORCH_WORK_DIR=${WORK_DIR} CCORCH_PROJECT_DIR=${PROJECT_DIR} CCORCH_TIMEOUT=${TIMEOUT} CCORCH_MAX_PANES=${MAX_PANES} CCORCH_MAX_CHILDREN_D1=${MAX_CHILDREN_D1} CCORCH_MAX_CHILDREN_D2=${MAX_CHILDREN_D2} CCORCH_PARENT_ID=${CHILD_ID} bash ${SCRIPT_DIR}/ccorch-wrapper.sh '<subtask>'\"
3. Wait in background: run tmux wait-for \${CHILD_CHANNEL} with run_in_background: true
4. After signal, read the grandchild's result file from ${WORK_DIR}/

## Pane Cleanup
After grandchildren complete, close their panes:
1. Read pane ID from .pane files: \`cat ${WORK_DIR}/<grandchild_id>.pane\`
2. Close: \`tmux kill-pane -t <pane_id>\`"

else
  SYSTEM_PROMPT="${SYSTEM_PROMPT}

## Depth Limit
You are at maximum depth (DEPTH=3). The Agent tool and \`tmux\` commands are denied for you, so you cannot create panes. \`git push\` is denied too.
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

# --- Export env vars for Stop hook ---
# The ccorch Stop hook (hooks/stop_signal.sh) reads these to signal the parent.

export CCORCH_PARENT_CHANNEL
export CCORCH_SESSION_ID
export CCORCH_DEPTH
export CCORCH_WORK_DIR
export CCORCH_PROJECT_DIR
export CCORCH_PARENT_PANE="${CCORCH_PARENT_PANE:-}"
export CCORCH_RESULT_FILE="$RESULT_FILE"

# --- Launch Claude Code (interactive mode) ---
# Interactive mode shows the TUI so users can see real-time progress.
# The Stop hook handles parent signaling on completion.

CURRENT_PANE="$CURRENT_PANE_ID"

# Build Claude command
# Panes run in auto mode, not with the permission bypass flag (removed in 0.6.0): under
# the bypass, allow rules have no effect and only deny rules hold, so --allowedTools
# restricted nothing. Each --disallowedTools value is one array element. The Bash deny
# rules catch the usual command form only and are not a security boundary (sh -c '...'
# or /usr/bin/x gets past them). The boundaries are the auto-mode classifier and the
# start gate above.
DENY_RULES=(
  'Bash(rm -rf *)'
  'Bash(git push --force *)'
  'Bash(git push -f *)'
  'Bash(git reset --hard *)'
  'Bash(git clean *)'
  'Bash(sudo *)'
)
if [ "$DEPTH" -ge 2 ]; then
  DENY_RULES+=('Bash(git push *)')   # only the Main Brain pushes
fi
if [ "$DEPTH" -ge 3 ]; then
  DENY_RULES+=('Agent' 'Bash(tmux *)')
fi

CLAUDE_CMD=(
  claude
  --permission-mode auto
  --disallowedTools "${DENY_RULES[@]}"
  --append-system-prompt "$SYSTEM_PROMPT"
)

# Dry run: the gate has passed; show what would start, then stop.
if [ -n "$DRY_RUN" ]; then
  printf '%s' "$SYSTEM_PROMPT" > "${WORK_DIR}/dry-run.system-prompt"
  echo "gate: ok"
  printf 'argv: %q\n' "${CLAUDE_CMD[@]}"
  exit 0
fi

# --- Write task to file for safe delivery ---
# Avoids send-keys escaping issues with special characters.

TASK_FILE="${WORK_DIR}/${CHILD_ID}-task.txt"
printf '%s' "$TASK" > "$TASK_FILE"

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

# Schedule task delivery after Claude TUI initializes
(
  sleep 3
  # Use load-buffer + paste-buffer for safe delivery of arbitrary text
  tmux load-buffer "$TASK_FILE"
  tmux paste-buffer -t "$CURRENT_PANE"
  sleep 0.5
  tmux send-keys -t "$CURRENT_PANE" Enter
) &
SENDER_PID=$!

# Launch Claude interactively (blocks until Claude exits)
"${CLAUDE_CMD[@]}" || true

# --- Post-execution ---
# Claude has exited (user typed /exit, pane was killed, or watchdog fired).

# Kill sender if still waiting
kill "$SENDER_PID" 2>/dev/null || true

# Kill watchdog (task completed before timeout)
kill "$WATCHDOG_PID" 2>/dev/null || true
unset WATCHDOG_PID

# Clean up task file
rm -f "$TASK_FILE"

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
