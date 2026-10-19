#!/bin/bash
# ccorch-wait.sh — wait until a job's (or a Main Brain's) result.md exists
#
# Usage: ccorch-wait.sh <work_dir> <channel>
#
# The same wait as /ccor's step 5, as a script, so a session isolated in a worktree (which
# refuses commands with loops and command substitution) can run it as one plain command.
# Run it in the background. On success it prints `result=<work_dir>/result.md` and exits 0.
# It exits 1, with the reason on stderr, when tmux wait-for fails, or when a signal came,
# there is no result.md and no depth-1 pane recorded in <work_dir> is alive within 10 s.
#
# A signal sent before the wait starts is not lost: tmux keeps it for the next wait-for.

set -u

[ "$#" -eq 2 ] || { echo "usage: ccorch-wait.sh <work_dir> <channel>" >&2; exit 2; }
WORK_DIR="$1"
CHANNEL="$2"
[ -d "$WORK_DIR" ] || { echo "ccorch-wait: not a directory: ${WORK_DIR}" >&2; exit 2; }
[ -n "$CHANNEL" ] || { echo "ccorch-wait: the channel is empty" >&2; exit 2; }

RESULT="${WORK_DIR}/result.md"
until [ -f "$RESULT" ]; do
  tmux wait-for "$CHANNEL" || { echo "ccorch-wait: tmux wait-for failed; see ${WORK_DIR}" >&2; exit 1; }
  [ -f "$RESULT" ] && break
  # A wrapper signals just before it exits: look for a live depth-1 pane for up to 10 s, so a
  # pane that is slow to close is not taken for a live one.
  alive=1
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    [ -f "$RESULT" ] && break 2
    live=$(tmux list-panes -a -F '#{pane_id}') || { echo "ccorch-wait: tmux list-panes failed; see ${WORK_DIR}" >&2; exit 1; }
    alive=""
    for f in "${WORK_DIR}"/depth1-*.pane; do
      [ -f "$f" ] && printf '%s\n' "$live" | grep -qxF -- "$(cat "$f")" && alive=1
    done
    [ -n "$alive" ] || break
  done
  [ -n "$alive" ] || { echo "ccorch-wait: no depth-1 pane is alive (or none was recorded) and there is no result.md; see ${WORK_DIR}" >&2; exit 1; }
done
echo "result=${RESULT}"
