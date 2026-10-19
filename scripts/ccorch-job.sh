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
# the pane's program to be the wrapper). tmux does expand formats (#{...}, #(...)) in some
# values, such as a window name and a start directory, so none of the caller's values goes
# into a window name, and a repository path with '#' is refused.
#
# The worktree name is checked here with the wrapper's own rule, so a bad one fails before
# tmux sees it; the wrapper's start gate checks it again. A name whose worktree directory
# already exists (<repository>/.claude/worktrees/<name>, where Claude Code puts it) is refused,
# so a job does not land in another job's worktree.
#
# The work directory is a fresh `mktemp -d` under ${TMPDIR:-/tmp}, readable by you only.
#
# Optional environment: CCORCH_MAX_PANES is passed on when set. CCORCH_TIMEOUT is not read:
# the timeout is the fourth argument, default 3600 seconds (/ccor's default of 600 is too short
# for a job that ends in a pull request). Needs tmux 3.0 or later (new-window -e).

set -euo pipefail
umask 077

die() { echo "ccorch-job: $*" >&2; exit 2; }
MAX_TASK_BYTES=100000   # the task becomes one argument; Linux limits one argument to 128 KiB

[ "$#" -ge 3 ] && [ "$#" -le 4 ] \
  || die "usage: ccorch-job.sh <repository> <worktree name> <task file> [timeout seconds]"
REPO_IN="$1"
WORKTREE_NAME="$2"
TASK_IN="$3"
TIMEOUT="${4:-3600}"

case "$TIMEOUT" in
  ''|*[!0-9]*|0*|???????*) die "timeout must be a positive integer of at most 6 digits (got '${TIMEOUT}')" ;;
esac
# The wrapper's rule for a worktree name (scripts/ccorch-wrapper.sh, start gate).
if ! ( LC_ALL=C; [[ "$WORKTREE_NAME" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,63}$ ]] ) \
   || [[ "$WORKTREE_NAME" == *..* ]]; then
  die "worktree name must be letters, digits, '.', '_' and '-', not start with '.' or '-', have no '..', and be at most 64 characters"
fi
[ -d "$REPO_IN" ] || die "not a directory: ${REPO_IN}"
REPO="$(cd "$REPO_IN" && pwd -P)"
case "$REPO" in *'#'*) die "the repository path contains '#', which tmux would read as a format: ${REPO}" ;; esac
TOP="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository: ${REPO}"
[ "$(cd "$TOP" && pwd -P)" = "$REPO" ] || die "give the repository's top directory (${TOP}), not ${REPO}"
[ ! -e "${REPO}/.claude/worktrees/${WORKTREE_NAME}" ] \
  || die "a worktree named ${WORKTREE_NAME} already exists: ${REPO}/.claude/worktrees/${WORKTREE_NAME}; pick another name"
[ -f "$TASK_IN" ] && [ -s "$TASK_IN" ] || die "task file is missing or empty: ${TASK_IN}"
TASK_BYTES=$(wc -c < "$TASK_IN")
[ "$TASK_BYTES" -le "$MAX_TASK_BYTES" ] \
  || die "task file is ${TASK_BYTES} bytes; at most ${MAX_TASK_BYTES} (point to files instead of copying them in)"
command -v tmux >/dev/null 2>&1 || die "tmux is required"
TMUX_VERSION="$(tmux -V 2>/dev/null || true)"
TMUX_MAJOR="${TMUX_VERSION#tmux }"; TMUX_MAJOR="${TMUX_MAJOR#next-}"; TMUX_MAJOR="${TMUX_MAJOR%%.*}"
case "$TMUX_MAJOR" in
  ''|*[!0-9]*) die "cannot read the tmux version ('${TMUX_VERSION}'); tmux 3.0 or later is required" ;;
esac
[ "$TMUX_MAJOR" -ge 3 ] || die "tmux 3.0 or later is required (found '${TMUX_VERSION}')"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${SCRIPT_DIR}/ccorch-wrapper.sh"
[ -f "$WRAPPER" ] || die "wrapper not found: ${WRAPPER}"

# One session per job: its own work directory (fresh, mode 700, unpredictable name) and
# channel (letters, digits and '_').
TMP_BASE="${TMPDIR:-/tmp}"
WORK_DIR="$(mktemp -d "${TMP_BASE%/}/ccorch-job.XXXXXX")" || die "cannot create a work directory under ${TMP_BASE}"
SESSION_ID="job-${WORK_DIR##*.}"
CHANNEL="CCORCH_DONE_${SESSION_ID//-/_}"
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
PANE_ID="$(tmux new-window -d -P -F '#{pane_id}' -n ccorch-job -c "$REPO" \
  "${ENV_ARGS[@]}" -- bash -c 'exec bash "$0" "$(cat "$1")"' "$WRAPPER" "$TASK_FILE")" \
  || die "tmux new-window failed"

echo "work_dir=${WORK_DIR}"
echo "channel=${CHANNEL}"
echo "pane=${PANE_ID}"
