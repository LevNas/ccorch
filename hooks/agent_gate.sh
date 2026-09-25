#!/bin/bash
# agent_gate.sh — Structural enforcement for agent spawning (ccorch v2).
#
# PreToolUse hook (matcher: Agent|Task). One guard remains:
#
#   Catalog tier guard: a ccorch catalog type runs on the tier its frontmatter
#   pins. An explicit model override is only legitimate as a deterministic
#   one-tier escalation after a failed run; anything beyond that is denied.
#
# What used to be here, and where it went (prefer official settings over
# custom mechanisms):
#
#   - Parallel cap (CCORCH_MAX_PARALLEL, ledger-derived) -> the official
#     CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS (the Agent tool refuses to spawn
#     past it). Related: CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY,
#     CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS.
#   - "No explicit model" deny for non-catalog spawns -> the official
#     CLAUDE_CODE_SUBAGENT_MODEL, which sets the default model for every
#     subagent that is not assigned one another way, so the expensive
#     main-session model is never inherited by accident. Add
#     CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1 to force it on every subagent.
#   - Spawn depth -> CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH.
#
#   Put them in the `env` block of ~/.claude/settings.json (or a project's
#   .claude/settings.json to share them with a team):
#
#     "env": {
#       "CLAUDE_CODE_SUBAGENT_MODEL": "sonnet",
#       "CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS": "3",
#       "CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH": "1"
#     }
#
# Configuration (environment):
#   CCORCH_GATE=off            disable the guard
#   CCORCH_MODEL_GUARD=off     same (kept for compatibility)
#
# Fail-open by design: missing jq or malformed input must never block a
# session — every uncertain path exits 0 (allow).

set -u
[ "${CCORCH_GATE:-on}" != "off" ] || exit 0
[ "${CCORCH_MODEL_GUARD:-on}" != "off" ] || exit 0
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

bare_type="${agent_type#ccorch:}"
catalog_tier=""
case "$bare_type" in
  url-extract|log-distiller)
    catalog_tier="haiku" ;;
  web-research|worktree-worker|impl-verifier|pbr-reviewer|kb-integrator|knowledge-recorder|web-refuter)
    catalog_tier="sonnet" ;;
esac
[ -n "$catalog_tier" ] || exit 0

tier_rank() {
  case "$1" in
    haiku*|claude-haiku*)                    echo 1 ;;
    sonnet*|claude-sonnet*)                  echo 2 ;;
    opus*|claude-opus*)                      echo 3 ;;
    fable*|claude-fable*|mythos*|claude-mythos*) echo 4 ;;
    *)                                       echo 0 ;;
  esac
}

if [ -n "$model" ] && [ "$model" != "inherit" ]; then
  want=$(tier_rank "$model")
  base=$(tier_rank "$catalog_tier")
  if [ "$want" -eq 0 ] || [ "$want" -gt $((base + 1)) ]; then
    deny "ccorch gate: '$bare_type' is pinned to $catalog_tier. The only allowed override is one tier up, for deterministic escalation after a failed run. Drop the model parameter or use the next tier."
  fi
fi

exit 0
