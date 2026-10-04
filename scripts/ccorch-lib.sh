#!/bin/bash
# ccorch-lib.sh — helpers shared by ccorch-wrapper.sh and ccorch-pane-died.sh (sourced, not run)

# publish_if_absent <tmp> <target>
# Puts <tmp> at <target> only when <target> has no result yet, and removes <tmp> either way.
# Returns 0 when <tmp> was published, 1 when <target> already held a result.
#
# `ln` fails atomically when <target> exists, so a pane that writes its result at the same
# moment is never overwritten: there is no gap between "is there a result?" and "write one".
# An empty <target> counts as no result, as everywhere else in ccorch, but a pane may be in
# the middle of writing it: wait CCORCH_PUBLISH_GRACE seconds (default 5), and replace it
# only if it is still empty.
publish_if_absent() {
  local tmp="$1" target="$2" grace="${CCORCH_PUBLISH_GRACE:-5}"
  if ln "$tmp" "$target" 2>/dev/null; then
    rm -f "$tmp"
    return 0
  fi
  if [ -e "$target" ] && [ ! -s "$target" ]; then
    sleep "$grace"
    if [ ! -s "$target" ] && mv "$tmp" "$target" 2>/dev/null; then
      return 0
    fi
  fi
  rm -f "$tmp"
  return 1
}
