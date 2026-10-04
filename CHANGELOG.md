# Changelog

Earlier versions: see the git history.

## 0.6.0 — 2026-10-04

The depth and pane limits are now enforced by the wrapper, and panes run in auto
mode ([DEC-006](docs/sdd/design/decisions/DEC-006.md), fixes #9).

### Changed

- Panes start with `--permission-mode auto` instead of the permission bypass flag.
  `--allowedTools` is gone: allow rules have no effect under the bypass.
  If the auto-mode classifier blocks an action, a pane may wait for a human.
- `--disallowedTools` is built per depth, one rule per element. Every depth denies
  `rm -rf`, force push, `git reset --hard`, `git clean` and `sudo`; depth 2 and 3
  also deny `git push`; depth 3 also denies `Agent` and `Bash(tmux *)`.
- The two `tmux split-pane` templates pass `CCORCH_MAX_PANES`,
  `CCORCH_MAX_CHILDREN_D1`, `CCORCH_MAX_CHILDREN_D2` and `CCORCH_PARENT_ID` to
  child panes. Before, the children limits never reached them.

### Added

- Start gate in `ccorch-wrapper.sh`: refuses a pane (result file `status: refused`
  with a reason, parent signalled) when the depth is not 1-3, when the live ccorch
  panes would exceed `CCORCH_MAX_PANES`, or when the live siblings under one parent
  would exceed `CCORCH_MAX_CHILDREN_D1` / `_D2`. The check runs under a portable
  `mkdir` lock (bounded wait, `CCORCH_LOCK_WAIT`, default 10 s, then refuse; a lock left by a killed
  wrapper is removed by hand and the refusal names it), not `flock`, so it works on macOS.
  Depth is derived from the parent's recorded depth (`<id>.depth`), not taken from
  `CCORCH_DEPTH`, and a session has one Main Brain. The gate fails closed: a limit that is
  not a positive integer, or a failing `tmux list-panes`, is a refusal. It bounds a model
  that uses the documented launch command; the auto-mode classifier is the boundary
  against anything else.
- `CCORCH_PARENT_ID` (set by each pane for its children; required at depth 2 and 3)
  and `CCORCH_DRY_RUN` (run the gate, print the `claude` arguments, start nothing).
- `tests/test_wrapper.sh`, run in CI.
- NFR-SEC-001 to 003 are "Implemented and unit-tested; live check pending" until the
  maintainer has run a live `/ccor`; Bash deny rules are still documented as not a boundary.

### Fixed

- If `claude` exits without writing a result file, the result is `status: error` with the
  exit code (non-zero exit) or `status: incomplete` (exit 0), not `status: success`.
- The deny list gains more of the common forms: `rm -fr`, `rm -r -f`, `rm -f -r`, `git push` with
  `--force` in any position (which includes `--force-with-lease`) and with a `+refspec`.
- A dry run writes no `.pane`, `.parent` or `.depth` record and leaves `status.md` alone;
  its prompt file is `<id>.dry-run.system-prompt` (see round 2 for where it goes now).
- The Main Brain's cleanup steps no longer delete every `.pane` file, which removed its own
  record, and `CHILD_ID` no longer depends on GNU `date +%N`.
- The system prompt and docs no longer present the Bash deny rules as hard limits.

### Review round 2

- The trap is installed before every check that can fail: a missing task argument, a bad
  `CCORCH_PROJECT_DIR` or a bad number is now a `status: refused` result with a signal.
  Only a missing `CCORCH_WORK_DIR` or `CCORCH_PARENT_CHANNEL` exits with a message (status 2).
  `WORK_DIR` and `PROJECT_DIR` are made absolute before any `cd`. `CCORCH_TIMEOUT` is validated.
- The pane id comes from `$TMUX_PANE`; an empty id or one not in `tmux list-panes` is refused.
- The lock records its owner's PID for the refusal message and is released by `cleanup()`.
- A Main Brain's result is copied to `result.md` when it wrote none, so a refusal is visible
  to the `/ccor` skill. The skill's error table says so.
- Dry runs write nothing in the live session: they print `out_dir: <temp dir>` and write the
  result, `status.md` and the prompt dump there, and take no lock.
- Front-matter values are sanitized to one line, so a value cannot add a second `status:` line.
- Pipelines on the task text (`echo | head`) are parameter expansions, so a large task cannot
  trip `pipefail` through SIGPIPE.
- More deny rules: `rm -Rf`, `rm -r --force`, `rm --recursive`, `git push` with `-f` in any
  position, `--delete` or a `:refspec`, `git branch -D`, and `git -C ... push` at depth 2 and 3.
  They are the common forms; DEC-006 lists the known gaps.

### Review round 3

- The lock is simpler: bounded wait (`CCORCH_LOCK_WAIT`, default 10), then refuse. Automatic
  stale-lock recovery is removed. A lock left by a killed wrapper is removed by hand; the
  refusal names the directory and the owner pid.
- The parent is always signalled: `cleanup()` starts with `set +e`, guards every write and
  sends the signal last, so a work directory that cannot be written no longer swallows it.
  `refuse()`, the watchdog and the dry-run prompt dump guard their writes the same way.
- A limit or timeout of more than 6 digits is refused.

## 0.5.0 — 2026-10-04

ccorch is now pane orchestration only ([DEC-005](docs/sdd/design/decisions/DEC-005.md)).

### Removed

- The 9 agent types `ccorch:*` (`agents/`), including `url-extract`
- The `/ccor-parallel` skill
- The hooks for the catalog tier guard and the agent ledger, and the ledger
  format document; `hooks/hooks.json` keeps only the Stop entry for
  `stop_signal.sh`
- Environment variables `CCORCH_GATE`, `CCORCH_MODEL_GUARD`, `CCORCH_MAX_PARALLEL`

### Where it went

If ccharness 0.9.0 is installed:

- `ccorch:<type>` (8 leaf types) → `ccharness:<type>`
- `/ccor-parallel` → `/ccharness:parallel-worktree`
- tier guard and ledger → ccharness; the ledger is now
  `<main checkout>/.claude/ccharness/ledger.jsonl`
- `url-extract` is retired, not moved; see [DEC-005](docs/sdd/design/decisions/DEC-005.md#what-was-retired)

### Migration

- Replace `ccorch:<type>` with `ccharness:<type>` in your own rules and prompts.
- Replace `/ccor-parallel` with `/ccharness:parallel-worktree`.
- Old ledger: delete `.claude/ccorch/ledger.jsonl` first, and only then drop its
  `.gitignore` line. In the other order, repositories that commit `.claude/`
  see the file appear as untracked.
- If your repository commits `.claude/`, ignore `.claude/ccharness/` as well.
- Environment variables `CCORCH_GATE`, `CCORCH_MODEL_GUARD` and
  `CCORCH_MAX_PARALLEL` no longer exist. Replacements:
  - `CCORCH_MAX_PARALLEL` (the parallel cap) → the official
    `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`, in the `env` block of your settings
  - `CCORCH_MODEL_GUARD` (the deny for spawns without a model) → the official
    `CLAUDE_CODE_SUBAGENT_MODEL`, in the `env` block of your settings
  - `CCORCH_GATE` (the catalog tier check; `CCORCH_MODEL_GUARD=off` was an alias
    of `CCORCH_GATE=off`) → ccharness's tier guard hook, if installed; its off
    switch is `CCHARNESS_TIER_GUARD=off`
- `/ccor` is unchanged.
