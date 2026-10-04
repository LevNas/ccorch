# Security Requirements

## NFR-SEC-001: Tool Restriction Enforcement

Even when using `--dangerously-skip-permissions`, restrictions via `--allowedTools` / `--disallowedTools` shall be enforced.

Status: Unverified. See [NFR-SEC-003](#nfr-sec-003-structural-depth-overflow-prevention) for the current state.

## NFR-SEC-002: Destructive Operation Prevention

Child panes shall not be able to execute destructive commands such as `git push --force`, `git reset --hard`, or `rm -rf /`. The intended mechanism is Bash tool pattern restrictions.

Status: Unverified. Today the ban is in the system prompt only; see [NFR-SEC-003](#nfr-sec-003-structural-depth-overflow-prevention).

## NFR-SEC-003: Structural Depth Overflow Prevention

Pane creation from DEPTH=3 panes shall be structurally prohibited at the CLI flag level. This is meant to prevent depth check bypass through prompt injection.

Status: Unverified.

### Current state (the one place this is explained)

What `scripts/ccorch-wrapper.sh` passes at each depth is tabled in [design/index.md](../../design/index.md#depth-based-tool-flags). What that means today:

- Every pane runs with `--dangerously-skip-permissions`, which `claude --help` describes as "Bypass all permission checks". The help text does not say whether `--allowedTools` or `--disallowedTools` still restrict anything under the bypass: **not verified**. The wrapper does not use `--permission-mode`.
- `--disallowedTools "Agent"` (DEPTH 3 only) denies the subagent tool. Panes are created with `tmux split-pane` through Bash, so this flag does not address pane creation. At DEPTH 3, pane creation is held back only by leaving `tmux:*` out of the Bash allowlist (not verified under the bypass) and by the system prompt. No code rejects a pane creation request or returns an error (US-002 REQ-002-003).
- The Bash patterns use commas inside the parentheses and a colon form, while the `claude --help` example is `"Bash(git *) Edit"`: how they are parsed is not verified.
- DEPTH 1 and 2 have identical allowlists.
- Destructive commands (`git push --force`, `git reset --hard`, `branch -D`, `rm -rf`) are banned only in each pane's system prompt.

## NFR-SEC-004: Session Isolation

Each orchestration session's working directory (`/tmp/ccorch/<session_id>/`) shall be isolated from other sessions.
