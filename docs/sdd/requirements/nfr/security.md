# Security Requirements

Status words used below: "Implemented and unit-tested (0.6.0); live check pending (see [DEC-006](../../design/decisions/DEC-006.md))" means the code and `tests/test_wrapper.sh` are in place, and the maintainer still has to run a live `/ccor` before the requirement is called Verified.

## NFR-SEC-001: Tool Restriction Enforcement

Tool restrictions on child panes shall hold in the permission mode the panes run in.

Status: Implemented and unit-tested (0.6.0); live check pending (see [DEC-006](../../design/decisions/DEC-006.md)). Panes run with `--permission-mode auto` and restrict tools only with `--disallowedTools`. Basis:

- Claude Code docs, permission modes: "Deny rules block in every mode, including `bypassPermissions`." and "Allow rules have no effect in `bypassPermissions`." Before 0.6.0 the wrapper passed the bypass flag with `--allowedTools`, so the allowlist restricted nothing.
- Test: `tests/test_wrapper.sh` asserts, at every depth, that the bypass flag and `--allowedTools` are absent, that `auto` follows `--permission-mode`, and that each deny rule is a whole argv element between `--disallowedTools` and `--append-system-prompt`.

This tests the arguments the wrapper builds. It does not test what a live `claude` does with them; that is the live check.

## NFR-SEC-002: Destructive Operation Prevention

Child panes shall not be able to execute destructive commands such as `git push --force`, `git reset --hard`, or `rm -rf /` in the usual command form.

Status: Implemented and unit-tested (0.6.0); live check pending (see [DEC-006](../../design/decisions/DEC-006.md)), as a rule layer and not as a boundary. Every depth denies `Bash(rm -rf *)`, `Bash(rm -fr *)`, `Bash(rm -r -f *)`, `Bash(rm -f -r *)`, `Bash(git push --force *)`, `Bash(git push *--force*)` (which also covers `--force-with-lease`), `Bash(git push -f *)`, `Bash(git push * +*)`, `Bash(git reset --hard *)`, `Bash(git clean *)` and `Bash(sudo *)`; depth 2 and 3 also deny `Bash(git push *)`, so only the Main Brain is meant to push. The test is `tests/test_wrapper.sh`.

**Bash deny rules are not a security boundary.** Claude Code docs, permissions: "a deny or ask rule covers the invocation Claude usually produces and isn't a security boundary around the program." Rules match the command text after compound commands are split and a fixed set of wrappers is stripped; they do not stop `sh -c '...'` or `/usr/bin/x`. The boundaries are the auto-mode classifier and the start gate (NFR-SEC-003). The instruction in the system prompt not to work around a denial is a rule the pane must follow; nothing enforces it.

## NFR-SEC-003: Structural Depth Overflow Prevention

Pane creation beyond the depth, pane and children limits shall be refused by code, not by prompt text.

Status: Implemented and unit-tested (0.6.0); live check pending (see [DEC-006](../../design/decisions/DEC-006.md)). Two layers:

- **Start gate** (`scripts/ccorch-wrapper.sh`): before `claude` starts, the wrapper refuses when a limit is not a positive integer, when `CCORCH_DEPTH` is not 1, 2 or 3, when `tmux list-panes` fails, or when the depth does not follow from the parent's record. Depth is not self-declared: each started pane records its depth in `<id>.depth` next to `<id>.pane` and `<id>.parent`; a pane at depth 2 or 3 needs a live parent record, and `CCORCH_DEPTH` must equal the parent's depth plus 1. One Main Brain per session: a second depth-1 start in a work directory with a live depth-1 record is refused. It also refuses when the live ccorch panes recorded in the work directory (compared with `tmux list-panes -a`) plus this one exceed `CCORCH_MAX_PANES`, or when the live siblings under the same parent plus this one exceed `CCORCH_MAX_CHILDREN_D1` (depth 2) or `CCORCH_MAX_CHILDREN_D2` (depth 3). A refusal writes `status: refused` with a one-line reason to the result file and signals the parent through the existing trap. The check holds a `mkdir` lock (`$WORK_DIR/.lock.d`, portable, with a 10 s timeout and stale-lock recovery) from counting until the records are written.
- **Depth 3 deny rules**: `Agent` and `Bash(tmux *)` are denied at depth 3. Pane creation is `tmux split-pane` through Bash, so denying `Agent` alone never addressed it. Deny rules apply in every mode (docs quote above), unlike the old allowlist. They catch the usual command form only.

The limits reach child panes because the two `tmux split-pane` command templates in the system prompt pass `CCORCH_MAX_PANES`, `CCORCH_MAX_CHILDREN_D1`, `CCORCH_MAX_CHILDREN_D2` and `CCORCH_PARENT_ID` explicitly. A pane made with `tmux split-pane "<cmd>"` takes its environment from the tmux server, not from the calling process, so without that the children would fall back to the defaults.

Test: `tests/test_wrapper.sh` (depth 4 refused, also in a real start with the parent signalled; depth that disagrees with the parent; missing or dead parent; second Main Brain; pane limit with 2 live, 3 live and 3 recorded with 1 dead; both children limits keyed on the pane's own depth; non-numeric limits; `list-panes` failing; the lock).

**What the gate bounds.** The gate bounds a model that uses the documented launch command. A process that rewrites its own environment, picks a new `CCORCH_WORK_DIR`, or runs `claude` directly without the wrapper can still escape it. Against that, the boundary is the auto-mode classifier, not the gate.

Findings about the old behaviour (0.5.0), kept for the record:

- The allow string `Bash(git:status,git:diff,git:add,git:commit,tmux:*)` is one literal prefix; commas are not a list separator in the documented syntax, so it matched no command. Under the bypass it was moot anyway.
- `CCORCH_MAX_PANES` reached the wrapper but was compared with nothing.
- `CCORCH_MAX_CHILDREN_D1` and `_D2` never reached child panes.

## NFR-SEC-004: Session Isolation

Each orchestration session's working directory (`/tmp/ccorch/<session_id>/`) shall be isolated from other sessions.
