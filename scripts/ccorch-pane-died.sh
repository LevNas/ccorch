#!/bin/bash
# ccorch-pane-died.sh — run by tmux (the pane-died hook) when a ccorch pane's program ended
# without the wrapper's own cleanup, for example when the wrapper was killed with SIGKILL.
#
# Usage: ccorch-pane-died.sh <result_file> <work_dir> <copy_result> <depth>
#
# The wrapper sets the hook before claude starts and removes it in its cleanup, so this runs
# only when that cleanup did not. It writes a "status: error" result unless the pane left a
# result, and for the Main Brain (copy_result=1) copies it to <work_dir>/result.md when that
# does not exist yet. The hook signals the parent after this script returns, so the parent
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

if [ "$COPY_RESULT" = 1 ] && [ -s "$RESULT_FILE" ] && [ ! -e "${WORK_DIR}/result.md" ]; then
  copy_tmp="${WORK_DIR}/result.md.pane-died-$$.tmp"
  { cp "$RESULT_FILE" "$copy_tmp" && mv "$copy_tmp" "${WORK_DIR}/result.md"; } 2>/dev/null \
    || rm -f "$copy_tmp" 2>/dev/null
fi
exit 0
