#!/bin/bash
# ccorch-job.sh — start one job pane for /ccorch:job
#
# Usage: ccorch-job.sh <repository> <worktree name> <task file> [timeout seconds]
#
# Opens a tmux window in <repository> that runs ccorch-wrapper.sh with CCORCH_MODE=job: the
# wrapper starts `claude --worktree <worktree name>` there and pastes the task file's text.
# Prints three lines for the caller:
#   work_dir=<the session's work directory>
#   channel=<the tmux wait-for channel the job signals>
#   pane=<the new pane's id>
# Wait with ccorch-wait.sh <work_dir> <channel>.
#
# The command goes to tmux as separate arguments, so no shell parses the task or the paths:
# tmux runs `bash -c` directly, and it execs the wrapper (the wrapper's pane-died hook needs
# the pane's program to be the wrapper). The worktree name is checked by the wrapper's start
# gate; a bad one comes back as a refused result, not as an error here.
#
# Optional environment: CCORCH_MAX_PANES is passed on when set. The timeout defaults to 3600
# seconds; /ccor's default of 600 is too short for a job that ends in a pull request.

set -euo pipefail

die() { echo "ccorch-job: $*" >&2; exit 2; }

[ "$#" -ge 3 ] && [ "$#" -le 4 ] \
  || die "usage: ccorch-job.sh <repository> <worktree name> <task file> [timeout seconds]"
REPO_IN="$1"
WORKTREE_NAME="$2"
TASK_IN="$3"
TIMEOUT="${4:-3600}"

case "$TIMEOUT" in
  ''|*[!0-9]*|0*|???????*) die "timeout must be a positive integer of at most 6 digits (got '${TIMEOUT}')" ;;
esac
[ -d "$REPO_IN" ] || die "not a directory: ${REPO_IN}"
REPO="$(cd "$REPO_IN" && pwd -P)"
TOP="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository: ${REPO}"
[ "$(cd "$TOP" && pwd -P)" = "$REPO" ] || die "give the repository's top directory (${TOP}), not ${REPO}"
[ -f "$TASK_IN" ] && [ -s "$TASK_IN" ] || die "task file is missing or empty: ${TASK_IN}"
command -v tmux >/dev/null 2>&1 || die "tmux is required"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${SCRIPT_DIR}/ccorch-wrapper.sh"
[ -f "$WRAPPER" ] || die "wrapper not found: ${WRAPPER}"

# One session per job: its own work directory and channel (letters, digits, '_' and '-').
SESSION_ID="job-$(date +%s)-$$"
WORK_DIR="${TMPDIR:-/tmp}/ccorch/${SESSION_ID}"
WORK_DIR="${WORK_DIR//\/\//\/}"
CHANNEL="CCORCH_DONE_${SESSION_ID//-/_}"
mkdir -p "$WORK_DIR"
# The task is read when the pane starts, so it is kept in the work directory, not at the
# caller's path, which the caller may change in the meantime.
TASK_FILE="${WORK_DIR}/job-task.md"
cp "$TASK_IN" "$TASK_FILE"

ENV_ARGS=(
  -e CCORCH_DEPTH=1
  -e "CCORCH_SESSION_ID=${SESSION_ID}"
  -e "CCORCH_PARENT_CHANNEL=${CHANNEL}"
  -e "CCORCH_WORK_DIR=${WORK_DIR}"
  -e "CCORCH_PROJECT_DIR=${REPO}"
  -e "CCORCH_TIMEOUT=${TIMEOUT}"
  -e CCORCH_MODE=job
  -e "CCORCH_WORKTREE=${WORKTREE_NAME}"
)
if [ -n "${CCORCH_MAX_PANES:-}" ]; then
  ENV_ARGS+=(-e "CCORCH_MAX_PANES=${CCORCH_MAX_PANES}")
fi

# -d: the caller's window stays active. Outside tmux ($TMUX empty, as in a background job),
# tmux picks the session to add the window to.
PANE_ID="$(tmux new-window -d -P -F '#{pane_id}' -n "job:${WORKTREE_NAME:0:20}" -c "$REPO" \
  "${ENV_ARGS[@]}" -- bash -c 'exec bash "$0" "$(cat "$1")"' "$WRAPPER" "$TASK_FILE")" \
  || die "tmux new-window failed"

echo "work_dir=${WORK_DIR}"
echo "channel=${CHANNEL}"
echo "pane=${PANE_ID}"
