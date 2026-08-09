#!/bin/bash
# agent_gate.sh — Structural enforcement for agent spawning (ccorch v2).
#
# PreToolUse hook (matcher: Agent|Task). Two guards:
#   1. Parallel cap: at most CCORCH_MAX_PARALLEL concurrently running agents,
#      derived from the ledger (best-effort).
#   2. Model routing: ccorch catalog types run on their pinned tier (one-tier
#      escalation allowed); non-catalog spawns must state a model explicitly,
#      so the expensive main-session model is never inherited by accident.
#      This also backstops the documented silent fallback: when a settings
#      allowlist excludes a frontmatter model, the subagent silently inherits
#      the main-session model.
#
# Configuration (environment):
#   CCORCH_GATE=off            disable both guards
#   CCORCH_MODEL_GUARD=off     disable guard 2 only
#   CCORCH_MAX_PARALLEL=N      cap for guard 1 (default 3)
#   CCORCH_GATE_EXEMPT_TYPES   comma list exempt from guard 2
#                              (default: claude-code-guide,statusline-setup)
#
# Fail-open by design: missing jq, malformed input, or unreadable ledger
# must never block a session — every uncertain path exits 0 (allow).

set -u
[ "${CCORCH_GATE:-on}" != "off" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat) || exit 0
[ -n "$input" ] || exit 0

tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
case "$tool" in Agent|Task) ;; *) exit 0 ;; esac

deny() {
  jq -cn --arg reason "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse",
                           permissionDecision: "deny",
                           permissionDecisionReason: $reason}}'
  exit 0
}

agent_type=$(printf '%s' "$input" | jq -r '.tool_input.subagent_type // "claude"' 2>/dev/null)
model=$(printf '%s' "$input" | jq -r '.tool_input.model // empty' 2>/dev/null)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)

# --- Guard 1: parallel cap --------------------------------------------------
max="${CCORCH_MAX_PARALLEL:-3}"
case "$max" in ''|*[!0-9]*) max=3 ;; esac
proj="${CLAUDE_PROJECT_DIR:-$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)}"
ledger="$proj/.claude/ccorch/ledger.jsonl"

if [ -n "$session_id" ] && [ -f "$ledger" ]; then
  # The ledger is written by jq -c with a fixed key order, so fixed-string
  # grep is safe and tolerates unrelated corrupt lines.
  launches=$(grep -F "\"session_id\":\"$session_id\"" "$ledger" 2>/dev/null \
    | grep -cF '"event":"launch"') || launches=0
  stops=$(grep -F "\"session_id\":\"$session_id\"" "$ledger" 2>/dev/null \
    | grep -cF '"event":"stop"') || stops=0
  running=$((launches - stops))
  [ "$running" -ge 0 ] || running=0
  if [ "$running" -ge "$max" ]; then
    deny "ccorch gate: $running agents already running in this session (cap $max). Wait for a completion notification and batch the remaining work into waves. If the ledger is stale, cross-check with ListAgents. Raise CCORCH_MAX_PARALLEL only if the host can take it."
  fi
fi

# --- Guard 2: model routing --------------------------------------------------
[ "${CCORCH_MODEL_GUARD:-on}" != "off" ] || exit 0

bare_type="${agent_type#ccorch:}"
catalog_tier=""
case "$bare_type" in
  url-extract|log-distiller)
    catalog_tier="haiku" ;;
  web-research|worktree-worker|impl-verifier|pbr-reviewer|kb-integrator|knowledge-recorder|web-refuter)
    catalog_tier="sonnet" ;;
esac

tier_rank() {
  case "$1" in
    haiku*|claude-haiku*)                    echo 1 ;;
    sonnet*|claude-sonnet*)                  echo 2 ;;
    opus*|claude-opus*)                      echo 3 ;;
    fable*|claude-fable*|mythos*|claude-mythos*) echo 4 ;;
    *)                                       echo 0 ;;
  esac
}

if [ -n "$catalog_tier" ]; then
  # Catalog type: frontmatter pins the model. An explicit override is only
  # legitimate as a deterministic one-tier escalation after a failed run.
  if [ -n "$model" ] && [ "$model" != "inherit" ]; then
    want=$(tier_rank "$model")
    base=$(tier_rank "$catalog_tier")
    if [ "$want" -eq 0 ] || [ "$want" -gt $((base + 1)) ]; then
      deny "ccorch gate: '$bare_type' is pinned to $catalog_tier. The only allowed override is one tier up, for deterministic escalation after a failed run. Drop the model parameter or use the next tier."
    fi
  fi
  exit 0
fi

exempt="${CCORCH_GATE_EXEMPT_TYPES:-claude-code-guide,statusline-setup}"
case ",$exempt," in *",$agent_type,"*) exit 0 ;; esac

if [ -z "$model" ]; then
  deny "ccorch gate: agent spawn without an explicit model inherits the main-session model, often the most expensive tier. Pick a ccorch catalog type (web-research, url-extract, log-distiller, worktree-worker, impl-verifier, pbr-reviewer, kb-integrator, knowledge-recorder, web-refuter) or set the model parameter deliberately. CCORCH_MODEL_GUARD=off disables this guard."
fi

exit 0
