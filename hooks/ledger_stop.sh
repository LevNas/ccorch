#!/bin/bash
# ledger_stop.sh — Append an agent-stop record to the ccorch ledger.
#
# SubagentStop hook. Balances the launch records so the parallel-cap guard
# can derive "running = launches - stops". A resumed agent may stop more than
# once; the resulting undercount only relaxes the cap (fail-open direction).
#
# Fail-open by design: never blocks.

set -u
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat) || exit 0
[ -n "$input" ] || exit 0

proj="${CLAUDE_PROJECT_DIR:-$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)}"
[ -n "$proj" ] || exit 0
ledger_dir="$proj/.claude/ccorch"
mkdir -p "$ledger_dir" 2>/dev/null || exit 0

printf '%s' "$input" | jq -c \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{schema: "ccorch.ledger/1",
    ts: $ts,
    event: "stop",
    session_id: (.session_id // null),
    agent_id: (.agent_id // null),
    agent_type: (.agent_type // null),
    stop_reason: (.stop_reason // null)}' \
  >> "$ledger_dir/ledger.jsonl" 2>/dev/null

exit 0
