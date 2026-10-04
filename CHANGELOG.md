# Changelog

Earlier versions: see the git history.

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
- `/ccor` is unchanged.
