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
#   CCORCH_LOCK_WAIT      — Seconds to wait for the start lock, then refuse (default: 10). A lock
#                           left by a killed wrapper is removed by hand; the refusal names it.
#   CCORCH_PARENT_PANE    — Parent's tmux pane ID (reserved for future layout use)
#   CCORCH_PARENT_ID      — Parent's child ID; required at depth 2 and 3, unset at depth 1.
#                           The depth must equal the parent's recorded depth + 1.
#   CCORCH_DRY_RUN        — If set, run the start gate read-only (no lock, no records), print
#                           "out_dir: <temp dir>" and the claude argv, and exit without
#                           starting claude. Every file it writes is in that temp dir.
#
# CCORCH_WORK_DIR and CCORCH_PARENT_CHANNEL are checked first (exit 2 if missing: no result
# or signal is possible without them); every later failure is a "refused" result.

set -euo pipefail

# --- Inputs that must exist before anything else ---
# Without a work directory there is nowhere to write a result file, and without a parent
# channel there is nothing to signal, so the parent could not be told about any failure.
# That is the one case that can only print to stderr and exit; everything after the trap
# below goes through refuse() instead.

if [ -z "${CCORCH_WORK_DIR:-}" ] || [ -z "${CCORCH_PARENT_CHANNEL:-}" ]; then
  echo "ccorch: CCORCH_WORK_DIR and CCORCH_PARENT_CHANNEL are required: without them no result can be written and the parent cannot be signalled" >&2
  exit 2
fi
PARENT_CHANNEL="$CCORCH_PARENT_CHANNEL"
DRY_RUN="${CCORCH_DRY_RUN:-}"

# Absolute paths before any cd, so the Stop hook and claude get the same directories.
abs_path() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$PWD" "$1" ;;
  esac
}
# WORK_DIR doubles as the state directory: the pane records and the lock live here, and a
# dry run only reads it.
WORK_DIR="$(abs_path "$CCORCH_WORK_DIR")"
PROJECT_DIR=""
if [ -n "${CCORCH_PROJECT_DIR:-}" ]; then
  PROJECT_DIR="$(abs_path "$CCORCH_PROJECT_DIR")"
fi

# OUT_DIR is where every write of this process goes: the result file, status.md, result.md
# and the prompt dump. Outside a dry run it is WORK_DIR. A dry run writes into a fresh
# temporary directory instead and leaves the live session untouched (and never creates it).
if [ -n "$DRY_RUN" ]; then
  OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ccorch-dry.XXXXXX")"
  echo "out_dir: ${OUT_DIR}"
else
  if ! mkdir -p "$WORK_DIR"; then
    echo "ccorch: cannot create CCORCH_WORK_DIR ${WORK_DIR}" >&2
    exit 2
  fi
  OUT_DIR="$WORK_DIR"
fi

TASK_GIVEN=""
TASK=""
if [ "$#" -ge 1 ]; then
  TASK_GIVEN=1
  TASK="$1"
fi
DEPTH="${CCORCH_DEPTH:-}"
SESSION_ID="${CCORCH_SESSION_ID:-}"
TIMEOUT="${CCORCH_TIMEOUT:-600}"
MAX_PANES="${CCORCH_MAX_PANES:-8}"
MAX_CHILDREN_D1="${CCORCH_MAX_CHILDREN_D1:-3}"
MAX_CHILDREN_D2="${CCORCH_MAX_CHILDREN_D2:-2}"
PARENT_ID="${CCORCH_PARENT_ID:-}"
LOCK_WAIT="${CCORCH_LOCK_WAIT:-10}"

# Everything that ends up in a front-matter line is sanitized: one line, no double quotes,
# no backslashes, bounded length. A value from the environment or the task must not be
# able to add a second `status:` line to a result file.
sanitize_to() { # sanitize_to <variable> <max length> <value>
  local v="$3"
  v="${v//$'\n'/ }"
  v="${v//$'\r'/ }"
  v="${v//\"/\'}"
  v="${v//\\/ }"
  printf -v "$1" '%s' "${v:0:$2}"
}
sanitize_to DEPTH_FM 20 "$DEPTH"
sanitize_to TASK_FM 100 "$TASK"

# Generate unique child ID. PID and $RANDOM, not date +%N: BSD date has no %N, and a
# shared ID would make panes overwrite each other's .pane/.parent/.depth files and
# defeat the gate. The depth label is 1, 2 or 3, and x for anything else, so that a
# hostile CCORCH_DEPTH cannot move the result file out of the work directory.
case "$DEPTH" in
  1|2|3) DEPTH_LABEL="$DEPTH" ;;
  *) DEPTH_LABEL="x" ;;
esac
CHILD_ID="depth${DEPTH_LABEL}-$$-${RANDOM}"
RESULT_FILE="${OUT_DIR}/${CHILD_ID}.md"
PANE_ID_FILE="${WORK_DIR}/${CHILD_ID}.pane"
PARENT_ID_FILE="${WORK_DIR}/${CHILD_ID}.parent"
DEPTH_FILE="${WORK_DIR}/${CHILD_ID}.depth"
LOCK_DIR="${WORK_DIR}/.lock.d"
LOCK_HELD=0
WATCHDOG_PID=""   # set only when the watchdog starts; never inherited from the environment
# A Main Brain's result also goes to result.md, where the user's session reads it.
COPY_RESULT=""
if [ "$DEPTH" = "1" ] && [ -z "$PARENT_ID" ]; then
  COPY_RESULT=1
fi

read_pid() { # read_pid <file> — prints the file's content if it is all digits, else nothing
  local v
  v="$(cat "$1" 2>/dev/null || true)"
  case "$v" in
    ''|*[!0-9]*) ;;
    *) printf '%s' "$v" ;;
  esac
}

# release_lock: LOCK_HELD is cleared first, so a signal that arrives during the release
# cannot release twice. Nothing else removes a lock, so no ownership check is needed.
release_lock() {
  if [ "$LOCK_HELD" = 1 ]; then
    LOCK_HELD=0
    rm -f "${LOCK_DIR}/owner" 2>/dev/null || true
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}

# --- Signal guarantee via trap ---
# The trap must exist before the start gate so that a refusal reaches the parent, and
# before every check that can fail. Bash keeps one EXIT trap: anything that must happen on
# exit, such as releasing the lock, goes through cleanup(), never through a second trap.

# cleanup() must reach the signal at its end whatever fails before it: set +e, and every
# write is guarded. The signal itself is skipped only for a dry run, which must not touch
# a live channel.
cleanup() {
  set +e
  release_lock

  # Kill watchdog if still running
  if [ -n "${WATCHDOG_PID:-}" ]; then
    kill "$WATCHDOG_PID" 2>/dev/null || true
  fi

  # Write a result if none exists yet: dry-run for a dry run, error otherwise
  if [ ! -s "$RESULT_FILE" ]; then
    local fallback_status="error" fallback_title="Error" fallback_body="Process terminated unexpectedly."
    if [ -n "$DRY_RUN" ]; then
      fallback_status="dry-run"
      fallback_title="Dry run"
      fallback_body="CCORCH_DRY_RUN was set; claude was not started."
    fi
    {
      cat > "${RESULT_FILE}.tmp" <<EOF
---
status: ${fallback_status}
depth: ${DEPTH_FM}
task: "${TASK_FM}"
completed: $(date -Iseconds)
---

# ${fallback_title}

${fallback_body}
EOF
    } 2>/dev/null || true
    mv "${RESULT_FILE}.tmp" "$RESULT_FILE" 2>/dev/null || true
  fi

  # The Main Brain's result reaches the user's session even when it ended without writing
  # result.md (refused, error, incomplete, timeout). The Stop hook also copies it on each
  # Stop once it exists; copy here when result.md is absent or differs from the result
  # file (by content, not mtime, so a rewrite within the same second is not missed). The
  # temporary name is per process, so a hook copying at the same moment cannot interleave.
  if [ -n "$COPY_RESULT" ] && [ -s "$RESULT_FILE" ] && ! cmp -s "$RESULT_FILE" "${OUT_DIR}/result.md"; then
    local copy_tmp="${OUT_DIR}/result.md.wrapper-$$.tmp"
    { cp "$RESULT_FILE" "$copy_tmp" && mv "$copy_tmp" "${OUT_DIR}/result.md"; } 2>/dev/null \
      || rm -f "$copy_tmp" 2>/dev/null
  fi

  # Always signal parent, last (a dry run must not touch a live channel)
  if [ -z "$DRY_RUN" ]; then
    tmux wait-for -S "$PARENT_CHANNEL" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# --- Start gate ---
# Computed refusal before claude starts. It checks that the inputs are sane, that the
# depth is 1-3 and follows from the parent's recorded depth, that the live ccorch panes
# stay within MAX_PANES, and that the live siblings under one parent stay within the
# per-depth children limit. Limits are enforced here, not by prompt text.
#
# What the gate bounds: a model that uses the documented launch command. A process that
# rewrites its own environment, picks a new CCORCH_WORK_DIR, or runs claude directly
# can still escape it. Against that, the boundary is the auto-mode classifier.

refuse() {
  local REASON_FM
  sanitize_to REASON_FM 200 "$1"
  {
    cat > "${RESULT_FILE}.tmp" <<EOF
---
status: refused
depth: ${DEPTH_FM}
reason: "${REASON_FM}"
task: "${TASK_FM}"
completed: $(date -Iseconds)
---

# Refused

${REASON_FM}
EOF
  } 2>/dev/null || true
  mv "${RESULT_FILE}.tmp" "$RESULT_FILE" 2>/dev/null || true
  echo "ccorch: refused: ${REASON_FM}" >&2
  if [ -n "$DRY_RUN" ]; then
    echo "gate: refused: ${REASON_FM}"
  fi
  exit 1
}

if [ -z "$TASK_GIVEN" ]; then
  refuse "usage: ccorch-wrapper.sh '<task description>' (the task argument is missing)"
fi
if [ -z "$SESSION_ID" ]; then
  refuse "CCORCH_SESSION_ID is required"
fi
if [ -z "$PROJECT_DIR" ]; then
  refuse "CCORCH_PROJECT_DIR is required"
fi

# Resolve the directory where this script lives (for child pane references)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Change to the user's project directory — all agents must run in the same context
if [ ! -d "$PROJECT_DIR" ] || ! cd "$PROJECT_DIR"; then
  refuse "CCORCH_PROJECT_DIR is not a directory I can enter: ${PROJECT_DIR}"
fi

# Fail closed: a limit or timeout that is not a positive integer would make every
# comparison below meaningless.
require_positive_int() {
  case "$2" in
    ''|*[!0-9]*|0*|???????*) refuse "$1 must be a positive integer (got '$2'; at most 6 digits)" ;;
  esac
}
require_positive_int CCORCH_TIMEOUT "$TIMEOUT"
require_positive_int CCORCH_MAX_PANES "$MAX_PANES"
require_positive_int CCORCH_MAX_CHILDREN_D1 "$MAX_CHILDREN_D1"
require_positive_int CCORCH_MAX_CHILDREN_D2 "$MAX_CHILDREN_D2"
require_positive_int CCORCH_LOCK_WAIT "$LOCK_WAIT"

case "$DEPTH" in
  1|2|3) ;;
  *) refuse "CCORCH_DEPTH must be 1, 2 or 3 (got '${DEPTH}')" ;;
esac

# Lock: mkdir is atomic and portable (flock is util-linux only). It is held from counting
# until the records are written, so simultaneous starts cannot both pass. A dry run takes
# no lock: it records nothing, so a race does not matter.
#
# Bounded wait, then refuse; there is no automatic recovery. A lock left by a killed
# wrapper is removed by hand, and the refusal reason names it.
acquire_lock() {
  local tries=0 max=$((LOCK_WAIT * 10))
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge "$max" ]; then
      return 1
    fi
    sleep 0.1
  done
  LOCK_HELD=1
  if ! printf '%s\n' "$$" > "${LOCK_DIR}/owner" 2>/dev/null; then
    release_lock
    return 2
  fi
}
if [ -z "$DRY_RUN" ]; then
  lock_rc=0
  acquire_lock || lock_rc=$?
  case "$lock_rc" in
    0) ;;
    2) refuse "lock: cannot write owner in ${LOCK_DIR}" ;;
    *)
      lock_owner="$(read_pid "${LOCK_DIR}/owner")"
      lock_note=""
      [ -z "$lock_owner" ] || lock_note=" (owner pid ${lock_owner})"
      refuse "lock timeout after ${LOCK_WAIT}s: ${LOCK_DIR}${lock_note}; if no ccorch pane is running, remove this directory and retry"
      ;;
  esac
fi

# This pane's id: $TMUX_PANE names the pane this process runs in; plain display-message
# would report the pane that is active in the session.
if [ -n "${TMUX_PANE:-}" ]; then
  CURRENT_PANE_ID="$(tmux display-message -p -t "$TMUX_PANE" '#{pane_id}' 2>/dev/null || true)"
else
  CURRENT_PANE_ID="$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)"
fi

# Fail closed: without the pane list every recorded pane would look dead.
if ! LIVE_PANES=$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null); then
  refuse "tmux list-panes failed; cannot tell which panes are alive"
fi

# Membership test without a pipe, so pipefail cannot turn a match into a failure.
is_live() {
  [ -n "$1" ] || return 1
  case $'\n'"$LIVE_PANES"$'\n' in
    *$'\n'"$1"$'\n'*) return 0 ;;
    *) return 1 ;;
  esac
}

if [ -z "$CURRENT_PANE_ID" ]; then
  refuse "cannot determine this pane's tmux id; is this running in tmux?"
fi
if ! is_live "$CURRENT_PANE_ID"; then
  refuse "this pane (${CURRENT_PANE_ID}) is not in the tmux pane list"
fi

# Depth is derived from the parent's recorded depth, not taken from the environment.
# Initialized here so that an inherited DERIVED_DEPTH cannot set it.
DERIVED_DEPTH=1
if [ -z "$PARENT_ID" ]; then
  if [ "$DEPTH" != "1" ]; then
    refuse "CCORCH_PARENT_ID is required at depth ${DEPTH}"
  fi
  # One Main Brain per session: refuse if another live depth-1 record exists.
  for depth_file in "${WORK_DIR}"/*.depth; do
    [ -e "$depth_file" ] || continue
    [ "$(cat "$depth_file" 2>/dev/null || true)" = "1" ] || continue
    other_pane=$(cat "${depth_file%.depth}.pane" 2>/dev/null || true)
    [ "$other_pane" != "$CURRENT_PANE_ID" ] || continue
    if is_live "$other_pane"; then
      # This work directory belongs to the Main Brain that is running: do not write
      # result.md into it.
      COPY_RESULT=""
      refuse "a Main Brain is already running in this session (pane ${other_pane})"
    fi
  done
else
  COPY_RESULT=""
  case "$PARENT_ID" in
    *[!A-Za-z0-9_-]*) refuse "CCORCH_PARENT_ID contains characters other than letters, digits, '-' and '_'" ;;
  esac
  PARENT_PANE_FILE="${WORK_DIR}/${PARENT_ID}.pane"
  PARENT_DEPTH_FILE="${WORK_DIR}/${PARENT_ID}.depth"
  if [ ! -f "$PARENT_PANE_FILE" ] || [ ! -f "$PARENT_DEPTH_FILE" ]; then
    refuse "no record of parent ${PARENT_ID} in ${WORK_DIR}"
  fi
  PARENT_PANE=$(cat "$PARENT_PANE_FILE" 2>/dev/null || true)
  PARENT_DEPTH=$(cat "$PARENT_DEPTH_FILE" 2>/dev/null || true)
  case "$PARENT_DEPTH" in
    1|2) ;;
    *) refuse "parent ${PARENT_ID} has an invalid recorded depth '${PARENT_DEPTH}'" ;;
  esac
  if ! is_live "$PARENT_PANE"; then
    refuse "parent ${PARENT_ID} is not alive (pane '${PARENT_PANE}')"
  fi
  DERIVED_DEPTH=$((PARENT_DEPTH + 1))
  if [ "$DEPTH" != "$DERIVED_DEPTH" ]; then
    refuse "CCORCH_DEPTH=${DEPTH} disagrees with the parent's recorded depth ${PARENT_DEPTH} (expected ${DERIVED_DEPTH})"
  fi
fi
# Every later decision (deny list, children limit, prompt) uses this depth.
DEPTH="$DERIVED_DEPTH"
CCORCH_DEPTH="$DEPTH"

LIVE_COUNT=0
SIBLING_COUNT=0
for pane_file in "${WORK_DIR}"/*.pane; do
  [ -e "$pane_file" ] || continue
  recorded_id=$(cat "$pane_file" 2>/dev/null || true)
  [ -n "$recorded_id" ] || continue
  [ "$recorded_id" != "$CURRENT_PANE_ID" ] || continue
  is_live "$recorded_id" || continue
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
  if [ $((SIBLING_COUNT + 1)) -gt "$CHILD_LIMIT" ]; then
    refuse "children limit reached: ${SIBLING_COUNT} live siblings under ${PARENT_ID}, ${LIMIT_NAME}=${CHILD_LIMIT}"
  fi
fi

# Records are written only for a real start: a dry run decides but leaves no trace in a
# live session. The lock is released here, before any subshell or claude starts.
if [ -z "$DRY_RUN" ]; then
  echo "$CURRENT_PANE_ID" > "$PANE_ID_FILE"
  echo "$DEPTH" > "$DEPTH_FILE"
  if [ -n "$PARENT_ID" ]; then
    echo "$PARENT_ID" > "$PARENT_ID_FILE"
  fi
fi
release_lock

# Set descriptive pane title based on depth
if [ -z "$DRY_RUN" ]; then
  TASK_SHORT="${TASK:0:40}"
  TASK_SHORT="${TASK_SHORT//$'\n'/ }"
  case "$DEPTH" in
    1) PANE_TITLE="[Main] ${TASK_SHORT}" ;;
    2) PANE_TITLE="[Child] ${TASK_SHORT}" ;;
    3) PANE_TITLE="[GChild] ${TASK_SHORT}" ;;
  esac
  tmux select-pane -t "$CURRENT_PANE_ID" -T "$PANE_TITLE" 2>/dev/null || true
fi

# The directories the rest of the script, the Stop hook and claude see are the resolved ones.
CCORCH_WORK_DIR="$WORK_DIR"
CCORCH_PROJECT_DIR="$PROJECT_DIR"

# --- Status dashboard ---

STATUS_FILE="${OUT_DIR}/status.md"

# Initialize status dashboard for Main Brain
if [ "$DEPTH" -eq 1 ]; then
  cat > "${STATUS_FILE}.tmp" <<EOF
# Orchestration Status

**Task**: ${TASK:0:200}
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
- Write your results to ${RESULT_FILE} when done, once, at the end. Your parent reads that file as your final answer as soon as it exists, so do not write a provisional or in-progress result there
- Write ${RESULT_FILE} (and, if you are the Main Brain, the status dashboard) with the Write tool (or Edit), not with \`mv\` or shell redirection. A user's ask rule on such commands overrides auto mode and stops this pane until a human answers
- No destructive git operations (push --force, reset --hard, branch -D)
- No destructive filesystem operations (rm -rf)
- Do not modify files outside the current working directory unless explicitly required by the task

## Permissions
- This pane runs in auto mode. An action the auto-mode classifier blocks may need a human to approve it in this pane; if you are blocked, say so in your result file instead of retrying another way round. Until that file exists your parent cannot tell a blocked pane from a busy one
- The common forms of some commands are denied by rule at this depth. The rules catch the usual command form only, so they are not a complete block. Do not work around a denial by another route (such as \`sh -c\` or a full path): that is a rule you must follow, not something the rules enforce"

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

The wrapper creates the file before you start. Read it, then rewrite the whole file with the Write tool (or change it with Edit). Do not use \`mv\` or shell redirection for it.

## Task Delegation Criteria
- Only delegate subtasks estimated at **10+ minutes** of work
- Tasks under 10 minutes: execute directly rather than paying the overhead of pane creation
- Ideal candidates: independent work on separate directories with minimal file overlap

## Child Pane Limits
- You may create at most **${MAX_CHILDREN_D1} child panes** concurrently
- At most **${MAX_PANES} live ccorch panes** in total, yourself included
- The wrapper enforces both limits: a child started over a limit does not run and returns \`status: refused\` with the reason in its result file. Treat that as the child's result, not as an error to work around
- Children run at DEPTH=2, may create at most ${MAX_CHILDREN_D2} grandchildren each, and should not push: the usual forms of \`git push\` are denied below the Main Brain, and not working around that is a rule they must follow
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
4. After signal, read the child's result file from ${WORK_DIR}/. A child signals at the end of each of its turns, not only when it is done: if its result file does not exist yet, the child is still working or is waiting for a human in its pane (look with \`tmux capture-pane -p -t <pane_id>\`), so wait on its channel again
5. Update the status dashboard with the child's result

## Worktree Usage
If the task involves code changes that could conflict between children:
- Use \`--worktree\` (\`-w\`) when launching Claude Code in child panes
- Branch naming convention: \`claude/<scope>-${SESSION_ID}\` (e.g., \`claude/auth-${SESSION_ID}\`, \`claude/tests-${SESSION_ID}\`)
- For research, analysis, or documentation tasks, worktree is unnecessary

## Pane Cleanup
After all children have completed and results are aggregated:
1. List completed panes: \`ls ${WORK_DIR}/*.pane\`. Your own record (${CHILD_ID}.pane) is among them: skip it
2. Close each of your children's panes: \`tmux kill-pane -t <pane_id>\` (read pane ID from .pane files). Never close your own pane: that ends this session before you write your result
3. Leave the \`.pane\` files in place (the wrapper ignores dead panes)
4. Update the status dashboard to reflect cleanup
Do this before you write your own result file: once that file exists, the user's session is told you are done and reads it."

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
- The usual forms of \`git push\` are denied for you; only the Main Brain pushes. Do not push by another route
- More panes does NOT mean faster — host resources become the bottleneck
- If you have more subtasks, run them in batches

## Creating Grandchild Panes
You can further delegate subtasks to grandchild panes (DEPTH=3, max depth). To create one:

1. Generate a channel name: CHILD_CHANNEL=\"CCORCH_\${SESSION_ID}_child_\$(date +%s%N | cut -c 11-16)\"
2. Launch via tmux:
   tmux split-pane -h \"CCORCH_DEPTH=${NEXT_DEPTH} CCORCH_SESSION_ID=${SESSION_ID} CCORCH_PARENT_CHANNEL=\${CHILD_CHANNEL} CCORCH_WORK_DIR=${WORK_DIR} CCORCH_PROJECT_DIR=${PROJECT_DIR} CCORCH_TIMEOUT=${TIMEOUT} CCORCH_MAX_PANES=${MAX_PANES} CCORCH_MAX_CHILDREN_D1=${MAX_CHILDREN_D1} CCORCH_MAX_CHILDREN_D2=${MAX_CHILDREN_D2} CCORCH_PARENT_ID=${CHILD_ID} bash ${SCRIPT_DIR}/ccorch-wrapper.sh '<subtask>'\"
3. Wait in background: run tmux wait-for \${CHILD_CHANNEL} with run_in_background: true
4. After signal, read the grandchild's result file from ${WORK_DIR}/. A grandchild signals at the end of each of its turns: if its result file does not exist yet, it is still working or is waiting for a human in its pane, so wait on its channel again

## Pane Cleanup
After grandchildren complete, close their panes, and do this before you write your own result file:
1. Read pane ID from .pane files: \`cat ${WORK_DIR}/<grandchild_id>.pane\`
2. Close: \`tmux kill-pane -t <pane_id>\`. Close only your grandchildren's panes, never your own (${CHILD_ID}.pane)"

else
  SYSTEM_PROMPT="${SYSTEM_PROMPT}

## Depth Limit
You are at maximum depth (DEPTH=3). The Agent tool and the usual forms of \`tmux\` commands are denied for you. You must not create panes by any route, and you must not push.
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

Write it with the Write tool, in one go, when you are done. Do not write it through a temporary file and \`mv\`."

# --- Export env vars for Stop hook ---
# The ccorch Stop hook (hooks/stop_signal.sh) reads these to signal the parent.

export CCORCH_PARENT_CHANNEL
export CCORCH_SESSION_ID
export CCORCH_DEPTH
export CCORCH_WORK_DIR
export CCORCH_PROJECT_DIR
export CCORCH_PARENT_PANE="${CCORCH_PARENT_PANE:-}"
export CCORCH_RESULT_FILE="$RESULT_FILE"
# Only the session's Main Brain has its result copied to result.md by the Stop hook.
export CCORCH_COPY_RESULT="$COPY_RESULT"

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
  'Bash(rm -fr *)'
  'Bash(rm -Rf *)'
  'Bash(rm -r -f *)'
  'Bash(rm -f -r *)'
  'Bash(rm -r --force *)'
  'Bash(rm --recursive *)'
  'Bash(git push --force *)'
  'Bash(git push *--force*)'
  'Bash(git push -f *)'
  'Bash(git push * -f*)'
  'Bash(git push * +*)'
  'Bash(git push *--delete*)'
  'Bash(git push * :*)'
  'Bash(git branch -D *)'
  'Bash(git reset --hard *)'
  'Bash(git clean *)'
  'Bash(sudo *)'
)
if [ "$DEPTH" -ge 2 ]; then
  DENY_RULES+=('Bash(git push *)' 'Bash(git -C * push*)')   # only the Main Brain pushes
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
  printf '%s' "$SYSTEM_PROMPT" > "${OUT_DIR}/${CHILD_ID}.dry-run.system-prompt" 2>/dev/null || true
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
  if [ ! -s "$RESULT_FILE" ]; then
    {
      cat > "${RESULT_FILE}.tmp" <<EOF
---
status: timeout
depth: ${DEPTH_FM}
task: "${TASK_FM}"
completed: $(date -Iseconds)
---

# Timeout

Task exceeded ${TIMEOUT}s timeout limit.
EOF
    } 2>/dev/null || true
    mv "${RESULT_FILE}.tmp" "$RESULT_FILE" 2>/dev/null || true
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
CLAUDE_RC=0
"${CLAUDE_CMD[@]}" || CLAUDE_RC=$?

# --- Post-execution ---
# Claude has exited (user typed /exit, pane was killed, or watchdog fired).

# Kill sender if still waiting
kill "$SENDER_PID" 2>/dev/null || true

# Kill watchdog (task completed before timeout)
kill "$WATCHDOG_PID" 2>/dev/null || true
unset WATCHDOG_PID

# Clean up task file
rm -f "$TASK_FILE"

# Claude exited without writing a result file. Exiting is not the same as succeeding:
# a non-zero exit is an error, and a clean exit is only "incomplete" because nothing
# says the task was done.
if [ ! -s "$RESULT_FILE" ]; then
  if [ "$CLAUDE_RC" -ne 0 ]; then
    FALLBACK_STATUS="error"
    FALLBACK_TITLE="Error"
    FALLBACK_BODY="claude exited with status ${CLAUDE_RC} and wrote no result file."
  else
    FALLBACK_STATUS="incomplete"
    FALLBACK_TITLE="Incomplete"
    FALLBACK_BODY="claude exited normally but wrote no result file; the task may not be done. Check the pane output."
  fi
  cat > "${RESULT_FILE}.tmp" <<EOF
---
status: ${FALLBACK_STATUS}
depth: ${DEPTH_FM}
exit_code: ${CLAUDE_RC}
task: "${TASK_FM}"
completed: $(date -Iseconds)
---

# ${FALLBACK_TITLE}

${FALLBACK_BODY}
EOF
  mv "${RESULT_FILE}.tmp" "$RESULT_FILE"
fi

# cleanup trap fires on exit → signals parent
