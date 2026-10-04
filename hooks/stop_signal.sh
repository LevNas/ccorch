#!/bin/bash
# stop_signal.sh — Signal parent on ccorch worker completion
#
# Only acts inside ccorch orchestration (CCORCH_PARENT_CHANNEL is set).
# No-op for normal Claude Code sessions.
#
# Stop fires at the end of every turn, not only when the pane is done.
#
# - Child and Grandchild panes signal their parent at every Stop, as before: a parent
#   (a model) checks the child's result file and waits again when there is none, so a
#   child that is stuck still reaches it.
# - The session's Main Brain (CCORCH_COPY_RESULT=1) signals the user's session only once
#   its result file exists and is non-empty, after copying it to
#   ${CCORCH_WORK_DIR}/result.md, so that session has something to read. Each later Stop
#   copies again, so a rewritten result is followed.
# - When that copy fails, the Main Brain does not signal: result.md would be missing or
#   older than the result. A later Stop copies again, and the wrapper copies and signals
#   when it ends.

[ -n "${CCORCH_PARENT_CHANNEL:-}" ] || exit 0

if [ "${CCORCH_COPY_RESULT:-}" = 1 ] && [ -n "${CCORCH_RESULT_FILE:-}" ]; then
  [ -s "$CCORCH_RESULT_FILE" ] || exit 0
  [ -n "${CCORCH_WORK_DIR:-}" ] || exit 0
  tmp="${CCORCH_WORK_DIR}/result.md.hook-$$.tmp"
  if ! { cp "$CCORCH_RESULT_FILE" "$tmp" && mv "$tmp" "${CCORCH_WORK_DIR}/result.md"; } 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    exit 0
  fi
fi

tmux wait-for -S "$CCORCH_PARENT_CHANNEL" 2>/dev/null || true
