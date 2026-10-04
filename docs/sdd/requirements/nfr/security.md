# Security Requirements

## NFR-SEC-001: Tool Restriction Enforcement

Even when using `--dangerously-skip-permissions`, restrictions via `--allowedTools` / `--disallowedTools` shall be enforced.

**Current state: not verified.** The wrapper passes `--dangerously-skip-permissions` at every depth, and `claude --help` describes it as "Bypass all permission checks". The help text does not say whether the allow and deny lists still restrict anything under the bypass.

## NFR-SEC-002: Destructive Operation Prevention

Child panes shall not be able to execute destructive commands such as `git push --force`, `git reset --hard`, or `rm -rf /`. The intended mechanism is Bash tool pattern restrictions.

**Current state:** no verified block. The Bash patterns sit in `--allowedTools`, which `claude --help` documents as an allow list; whether it restricts under the bypass is not verified. The destructive-command ban is stated only in each pane's system prompt.

## NFR-SEC-003: Structural Depth Overflow Prevention

Pane creation from DEPTH=3 panes shall be structurally prohibited at the CLI flag level. This is meant to prevent depth check bypass through prompt injection by controlling at the CLI flag level.

**Current state:** `--disallowedTools "Agent"` (DEPTH 3 only) denies the subagent tool. Panes are created with `tmux split-pane` through Bash, so this flag does not address pane creation. At DEPTH 3, pane creation is held back only by leaving `tmux:*` out of the Bash allowlist (not verified under `--dangerously-skip-permissions`) and by the system prompt.

## NFR-SEC-004: Session Isolation

Each orchestration session's working directory (`/tmp/ccorch/<session_id>/`) shall be isolated from other sessions.
