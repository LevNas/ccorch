# Security Requirements

## NFR-SEC-001: Tool Restriction Enforcement

Even when using `--dangerously-skip-permissions`, restrictions via `--allowedTools` / `--disallowedTools` shall be enforced.

**Current state: not verified.** The wrapper passes `--dangerously-skip-permissions` at every depth, and `claude --help` describes it as "Bypass all permission checks". The help text does not say whether the allow and deny lists still restrict anything under the bypass.

## NFR-SEC-002: Destructive Operation Prevention

Child panes shall not be able to execute destructive commands such as `git push --force`, `git reset --hard`, or `rm -rf /`. The intended mechanism is Bash tool pattern restrictions.

**Current state:** no verified block. The Bash patterns sit in `--allowedTools`, which `claude --help` documents as an allow list; whether it restricts under the bypass is not verified. The destructive-command ban is stated only in each pane's system prompt.

## NFR-SEC-003: Structural Depth Overflow Prevention

Agent tool invocations from DEPTH=3 panes shall be structurally prohibited via `--disallowedTools`. This is meant to prevent depth check bypass through prompt injection by controlling at the CLI flag level.

**Current state:** the wrapper passes `--disallowedTools "Agent"` at DEPTH 3 only; whether it is enforced under `--dangerously-skip-permissions` is not verified. The DEPTH 3 system prompt also forbids creating panes.

## NFR-SEC-004: Session Isolation

Each orchestration session's working directory (`/tmp/ccorch/<session_id>/`) shall be isolated from other sessions.
