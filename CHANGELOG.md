# Changelog

Earlier versions: see the git history.

## 0.6.3 — 2026-10-05

The four NITs deferred from #13's review (refs #11).

### Fixed

- **A pane killed with SIGKILL left its parent waiting.** The wrapper's trap does not run on
  SIGKILL, so there was no result and no signal; a parent waited until its own
  `CCORCH_TIMEOUT`, and `/ccor` waited for ever for a Main Brain. Before `claude` starts, the
  wrapper now sets `remain-on-exit on` and a pane-level `pane-died` hook on its own pane. tmux
  runs the hook when the pane's program dies: `scripts/ccorch-pane-died.sh` writes
  `status: error` unless the pane left a result (and, for a Main Brain, copies the result to
  `result.md` when that is absent or differs), then the hook signals the parent and closes the
  pane. `cleanup()` removes both, so a normal exit still signals once. A pane-level
  `pane-exited` hook does not work (it goes away with the pane), and a server-level hook would
  change the user's tmux settings. A pane-level `remain-on-exit` or `pane-died` the user had
  set on that pane is lost. The shell tmux starts the pane with must exec the wrapper (checked
  for zsh and bash). Checked only on tmux 3.7b with a private server and a fake `claude`
  (`tests/test_tmux_hook.sh`); a live check on 2026-10-05 with a real Claude child pane killed
  with SIGKILL passed (DEC-006, Consequences). Not covered: a SIGKILL
  before the hook is set (during the start gate, or between arming the hook and starting
  `claude`), and one during `cleanup()` after the hook is removed and before the trap's
  result and signal.
- **The watchdog could overwrite a result written at the last moment.** It tested for a
  result and then `mv`ed `status: timeout` over the file, and killed the pane either way. It
  now publishes with `publish_if_absent` (new `scripts/ccorch-lib.sh`): `ln` fails when the
  result exists, so there is no gap between the check and the write, and the pane is killed
  unless the pane's own result is there. The gap is closed by `ln`, not caught by a test; the
  tests show that `publish_if_absent` never replaces a non-empty result (also with `mv -n`
  where hard links are not available). An empty result file is still "no result", but is
  replaced only if it stays empty for `CCORCH_PUBLISH_GRACE` seconds (default 5); that
  replacement is a check and then a `mv`, so a write in the instant between them is lost.
- **The Stop hook signalled even when its copy to `result.md` failed**, so the user's session
  could read a missing or older `result.md`. The Main Brain now signals only after a
  successful copy. When the wrapper's own copy fails at exit, it removes an older `result.md`
  that differs from the result file, and `/ccor`'s wait loop stops (with a message pointing to
  the work directory) when a signal comes, `result.md` is missing and no Main Brain pane is
  alive.
- **Tests** for all three: `tests/test_wrapper.sh` (311 tests) and the new
  `tests/test_tmux_hook.sh`. Each fix was undone once by hand to see a new test fail.

## 0.6.2 — 2026-10-05

A problem found by the 0.6.1 live check (refs #11).

### Fixed

- **Panes stopped at their first read of the session directory.** 0.6.1 has panes write
  `status.md` and result files with the Read and Write tools. The session directory
  (`/tmp/ccorch/<id>`) is outside the project, and in the live check (Claude Code
  v2.1.288) the Main Brain's first Read of `status.md` asked "Allow this read outside the
  working directories?" in auto mode, so the pane waited for a human. The 0.6.0 live check
  did not stop there, probably because 0.6.0 wrote these files with shell commands rather
  than the file tools. The wrapper now
  passes the session directory to `claude` with `--add-dir`, at every depth. This is
  expected to stop the prompt (`--add-dir` gives the tools access to that directory); it had
  not been checked live at release.
- The 0.6.1 live check stopped at that prompt, before any `mv` or completion signal, so at
  release 0.6.1's changes had not been checked live.
- (Since then, the 0.6.2 live check on 2026-10-05 showed, for one Main Brain: no prompt for
  the file tools in the session directory (`--add-dir`), result writes with the Write tool
  and no `mv`, and `result.md` present at the first signal. Not exercised: a child that runs,
  `/ccor`'s wait loop, a Grandchild, a denied command. See
  [DEC-006](docs/sdd/design/decisions/DEC-006.md) and #11.)

## 0.6.1 — 2026-10-04

Two problems found by the 0.6.0 live check (refs #11).

### Fixed

- **The user's session was signalled before there was a result to read.** The Stop hook
  runs at the end of every turn and signalled every time; in the live check the user's
  session was woken three times before `result.md` existed. For the session's Main Brain,
  the hook now signals only once its result file exists and is non-empty, after copying it
  to `result.md`. `/ccor` waits again until `result.md` exists, and stops instead of
  spinning if `tmux wait-for` fails. The wrapper's exit copies the result again when
  `result.md` is absent or differs from it.
- Children and grandchildren still signal their parent at every turn: their parent now
  checks for the child's result file and waits again when there is none. Gating them too
  would hide a stuck child, because a parent's own timeout runs out first.
- An empty result file counts as no result: the watchdog and the wrapper's exit write their
  own result over it.
- **Panes stopped at a user's ask rule on `mv`.** The prompt told panes to write
  `status.md` and the result file through a temporary file and `mv`; an ask rule such as
  `Bash(mv *)` overrides auto mode, so the pane waited for a human. Panes now write both
  with the Write tool (or Edit). `/ccor` no longer deletes `.pane` files with `rm` in its
  cleanup step; the wrapper ignores dead panes.

### Changed

- The prompt says the result file is the final answer: write it once, at the end, and do not
  write a provisional result there. The Main Brain and children close their children's
  panes, never their own, before writing their own result.
- A Main Brain that is stuck and has written no result no longer wakes the user's session at
  every turn; the session hears from it when the Main Brain's `CCORCH_TIMEOUT` runs out.

## 0.6.0 — 2026-10-04

The depth and pane limits are now enforced by the wrapper, and panes run in auto
mode ([DEC-006](docs/sdd/design/decisions/DEC-006.md), fixes #9).

### Upgrading from 0.5.x

- **Panes may now stop and ask you.** Up to 0.5.x, panes ran with the
  permission bypass and did not prompt for ordinary actions. From 0.6.0 they
  run in auto mode, and a pane waits for a human when the classifier blocks an
  action. A pane still waiting when `CCORCH_TIMEOUT` (default 600 s) runs out
  is stopped with `status: timeout`. Watch the panes of a long run instead of
  leaving it unattended.
- **Without auto mode, every pane prompts.** When auto mode is not available to
  the pane's session (a model that does not support it, auto mode turned off
  with the `disableAutoMode` setting, or turned off by Anthropic), Claude Code
  starts each pane in Manual mode, which asks before most actions. See
  [permission modes](https://code.claude.com/docs/en/permission-modes) for the
  supported models and the
  [settings reference](https://code.claude.com/docs/en/settings-reference) for
  the setting. A pane's status bar shows `auto mode on` only when auto mode is
  active. The start gate and the deny rules apply in every mode.
- **The limits are now real.** The defaults are `CCORCH_MAX_PANES=8`,
  `CCORCH_MAX_CHILDREN_D1=3` and `CCORCH_MAX_CHILDREN_D2=2`, counted on live
  panes. Before, the children limits never reached child panes. Set lower
  values in the `env` block of your settings if your host is small.
- **A refused pane is a result, not a failure.** A pane over a limit does not
  start; its result file says `status: refused` with the reason.
- **A leftover start lock is removed by hand.** The lock is per run
  (`/tmp/ccorch/<session>/.lock.d`). If a wrapper is killed while it holds the
  lock, later panes of the same run wait (10 s) and are refused with the lock
  path in the reason. Remove that directory once no pane of that run is
  running; a new `/ccor` run uses a new directory and is not affected.

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
  (Since verified by the 2026-10-04 live check, with stated gaps; see
  [DEC-006](docs/sdd/design/decisions/DEC-006.md).)

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
