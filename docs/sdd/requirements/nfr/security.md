# Security Requirements

## NFR-SEC-001: Tool Restriction Enforcement

Even when using `--dangerously-skip-permissions`, restrictions via `--allowedTools` / `--disallowedTools` shall be enforced.

## NFR-SEC-002: Destructive Operation Prevention

Child panes shall not be able to execute destructive commands such as `git push --force`, `git reset --hard`, or `rm -rf /`. These shall be structurally blocked via Bash tool pattern restrictions.

## NFR-SEC-003: Structural Depth Overflow Prevention

Agent tool invocations from DEPTH=3 panes shall be structurally prohibited via `--disallowedTools`. This prevents depth check bypass through prompt injection by controlling at the CLI flag level.

## NFR-SEC-004: Session Isolation

Each orchestration session's working directory (`/tmp/ccorch/<session_id>/`) shall be isolated from other sessions.
