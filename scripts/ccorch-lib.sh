#!/bin/bash
# ccorch-lib.sh — helpers shared by ccorch-wrapper.sh and ccorch-pane-died.sh (sourced, not run)

# publish_if_absent <tmp> <target>
# Puts <tmp> at <target> only when <target> has no result yet, and removes <tmp> either way.
# Returns 0 when <tmp> was published, 1 when <target> already held a result.
#
# `ln` fails atomically when <target> exists, so a non-empty result a pane wrote is never
# overwritten. Where hard links are not available (`ln` fails and <target> does not exist),
# `mv -n` is used instead; it does not replace an existing file either, and <tmp> still being
# there afterwards means it was not moved.
# An empty <target> counts as no result, as everywhere else in ccorch, but a pane may be in
# the middle of writing it: wait CCORCH_PUBLISH_GRACE seconds (default 5), and replace it if
# it is still empty. That last step is a check and then a `mv`, not atomic: a pane that
# writes in the instant between them loses its write.
publish_if_absent() {
  local tmp="$1" target="$2" grace="${CCORCH_PUBLISH_GRACE:-5}"
  if ln "$tmp" "$target" 2>/dev/null; then
    rm -f "$tmp"
    return 0
  fi
  if [ ! -e "$target" ]; then
    mv -n "$tmp" "$target" 2>/dev/null
    if [ ! -e "$tmp" ] && [ -s "$target" ]; then
      return 0
    fi
  fi
  if [ -e "$target" ] && [ ! -s "$target" ] && [ -e "$tmp" ]; then
    sleep "$grace"
    if [ ! -s "$target" ] && mv "$tmp" "$target" 2>/dev/null; then
      return 0
    fi
  fi
  rm -f "$tmp"
  return 1
}
