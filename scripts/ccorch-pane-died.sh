#!/bin/bash
# ccorch-pane-died.sh — run by tmux (the pane-died hook) when a ccorch pane's program ended
# without the wrapper's own cleanup, for example when the wrapper was killed with SIGKILL.
#
# Usage: ccorch-pane-died.sh <result_file> <work_dir> <copy_result> <depth>
#
# The wrapper sets the hook before claude starts and removes it in its cleanup, so this runs
# only when that cleanup did not. It writes a "status: error" result unless the pane left a
# result, and for the Main Brain (copy_result=1) copies the result to <work_dir>/result.md
# when that is absent or differs. The hook signals the parent after this script returns, so the parent
# finds a result file and does not wait again.

set -u

RESULT_FILE="${1:-}"
WORK_DIR="${2:-}"
COPY_RESULT="${3:-}"
DEPTH="${4:-}"
[ -n "$RESULT_FILE" ] && [ -n "$WORK_DIR" ] || exit 0

# shellcheck source=ccorch-lib.sh
. "$(dirname "$0")/ccorch-lib.sh"

case "$DEPTH" in
  1|2|3) ;;
  *) DEPTH="x" ;;
esac

tmp="${RESULT_FILE}.pane-died-$$.tmp"
if cat > "$tmp" 2>/dev/null <<EOF
---
status: error
depth: ${DEPTH}
task: "(see the pane's task file and status.md)"
completed: $(date -Iseconds)
---

# Error

The pane's program ended without the wrapper's cleanup (for example, the wrapper was killed
with SIGKILL), and the pane wrote no result file. tmux ran this script from the pane's
pane-died hook.
EOF
then
  publish_if_absent "$tmp" "$RESULT_FILE" || true
else
  rm -f "$tmp" 2>/dev/null
fi

# The same rule as the wrapper's cleanup() after claude ran: copy when result.md is absent or
# differs, so a result rewritten after the last Stop is not hidden by an older copy. If the
# copy fails, an older result.md is removed rather than read as this result. The hook is set
# after the start gate and just before claude starts, so any older result.md here belongs to
# this session's earlier Main Brain, never to another one running now (a second one is
# refused at the gate, before the hook is set).
if [ "$COPY_RESULT" = 1 ] && [ -s "$RESULT_FILE" ] \
   && ! cmp -s "$RESULT_FILE" "${WORK_DIR}/result.md" 2>/dev/null; then
  copy_tmp="${WORK_DIR}/result.md.pane-died-$$.tmp"
  if ! { cp "$RESULT_FILE" "$copy_tmp" && mv "$copy_tmp" "${WORK_DIR}/result.md"; } 2>/dev/null; then
    rm -f "$copy_tmp" "${WORK_DIR}/result.md" 2>/dev/null
  fi
fi
exit 0
