#!/bin/bash
# stop_signal.sh — Signal parent on ccorch worker completion
#
# Only acts inside ccorch orchestration (CCORCH_PARENT_CHANNEL is set).
# No-op for normal Claude Code sessions.
#
# Stop fires at the end of every turn, not only when the pane is done. The pane's
# result file is the completion signal: until it exists and is non-empty, the parent
# is not woken (it would find nothing to read). A pane started by an older wrapper
# has no CCORCH_RESULT_FILE; it signals on every Stop, as before.
#
# For the Main Brain (CCORCH_COPY_RESULT=1), the result is also copied to
# ${CCORCH_WORK_DIR}/result.md before the signal, so the user's session can read it
# while the Main Brain's session is still open. Each Stop after a rewrite copies again.

[ -n "${CCORCH_PARENT_CHANNEL:-}" ] || exit 0

if [ -n "${CCORCH_RESULT_FILE:-}" ]; then
  [ -s "$CCORCH_RESULT_FILE" ] || exit 0
  if [ "${CCORCH_COPY_RESULT:-}" = 1 ] && [ -n "${CCORCH_WORK_DIR:-}" ]; then
    { cp "$CCORCH_RESULT_FILE" "${CCORCH_WORK_DIR}/result.md.tmp" \
        && mv "${CCORCH_WORK_DIR}/result.md.tmp" "${CCORCH_WORK_DIR}/result.md"; } 2>/dev/null || true
  fi
fi

tmux wait-for -S "$CCORCH_PARENT_CHANNEL" 2>/dev/null || true
