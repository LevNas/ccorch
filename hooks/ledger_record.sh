#!/bin/bash
# ledger_record.sh — Append an agent-launch record to the ccorch ledger.
#
# PostToolUse hook (matcher: Agent|Task). Agents do not know their own
# agentId, so the orchestrator side must record it at spawn time; a missed
# entry means a lost resume handle (SendMessage needs the id).
#
# The agentId is not a documented field of tool_response, so it is extracted
# from the response text pattern "agentId: <id>" when present and recorded as
# null otherwise (the launch still counts for the parallel-cap guard).
#
# Fail-open by design: never blocks, never fails the tool call.

set -u
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat) || exit 0
[ -n "$input" ] || exit 0

tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
case "$tool" in Agent|Task) ;; *) exit 0 ;; esac

proj="${CLAUDE_PROJECT_DIR:-$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)}"
[ -n "$proj" ] || exit 0
ledger_dir="$proj/.claude/ccorch"
mkdir -p "$ledger_dir" 2>/dev/null || exit 0

agent_id=$(printf '%s' "$input" \
  | jq -r '.tool_response | tostring' 2>/dev/null \
  | grep -oE 'agentId: [A-Za-z0-9_-]+' | head -n1 | cut -d' ' -f2)

# Note the deliberate minimalism: `thread` stores only the short description
# parameter, never the prompt body (secrets baseline for persisted state).
printf '%s' "$input" | jq -c \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg agent_id "${agent_id:-}" \
  '{schema: "ccorch.ledger/1",
    ts: $ts,
    event: "launch",
    session_id: (.session_id // null),
    agent_id: (if $agent_id == "" then null else $agent_id end),
    agent_type: (.tool_input.subagent_type // "claude"),
    model: (.tool_input.model // null),
    background: (if (.tool_input | has("run_in_background")) then .tool_input.run_in_background else true end),
    thread: (.tool_input.description // null)}' \
  >> "$ledger_dir/ledger.jsonl" 2>/dev/null

exit 0
