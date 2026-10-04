# ccorch

> **Status: Experimental** — This plugin is in early development. Each orchestration session spawns multiple Claude Code instances, which can consume significant tokens. Use with caution and monitor your usage.

tmux pane orchestration for Claude Code. `/ccor` splits work into **separate
sessions** — a Main Brain pane that delegates to Child and Grandchild panes —
and collects their results through files and `tmux wait-for` signals.

Since 0.5.0 ccorch does only this. Distribution of work *inside* one session
(leaf agents, parallel worktree fan-out) moved out of ccorch; if installed,
ccharness provides it — see
[Moved to ccharness (0.9.0)](#moved-to-ccharness-090).

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI
- [tmux](https://github.com/tmux/tmux) 1.8+ (required; `/ccor` must run inside a tmux session)

## Installation

```bash
# Add the marketplace
/plugin marketplace add LevNas/claudecode-plugins

# Install the plugin
/plugin install ccorch@levnas-plugins
```

Step-by-step walkthrough — repository layout, user scope, first run,
ccmemo integration: [docs/getting-started.md](docs/getting-started.md)
([日本語](docs/getting-started.ja.md)).

## When to use panes

Use `/ccor` only for:

1. Work that **writes to another repository**
2. Work that must run under the **target repository's permission/hook layer**
3. Work that needs **real-time visual supervision**

For anything else, stay in one session. Design rationale:
[DEC-004](docs/sdd/design/decisions/DEC-004.md) (the three conditions) and
[DEC-005](docs/sdd/design/decisions/DEC-005.md) (the narrowing).

## `/ccor`

```
/ccor <task description>
```

Example:

```
/ccor Refactor the authentication module — extract middleware, add unit tests, update API docs
```

## How It Works

```
Your Session ──► Main Brain (DEPTH=1)
                  ├── Child A (DEPTH=2)
                  │     └── Grandchild A-1 (DEPTH=3)
                  └── Child B (DEPTH=2)
                        └── Grandchild B-1 (DEPTH=3)
```

1. `/ccor` creates a **Main Brain** pane that analyzes and decomposes your task
2. Main Brain delegates subtasks to **Child** panes for parallel execution
3. Children can further delegate to **Grandchild** panes (max depth)
4. Results flow back up via `tmux wait-for` signals and file exchange under `/tmp/ccorch/<session_id>/`
5. Your session continues working in parallel — you're notified on completion

### Safety

- **Permissions are bypassed**: every pane starts with `--dangerously-skip-permissions`. Whether the `--allowedTools` / `--disallowedTools` flags restrict anything under it is unverified; [NFR-SEC-003](docs/sdd/requirements/nfr/security.md#nfr-sec-003-structural-depth-overflow-prevention) has the details
- **Guard rails**: destructive commands (`git push --force`, `git reset --hard`, `branch -D`, `rm -rf`) and pane creation at DEPTH 3 are forbidden in each pane's system prompt (`--append-system-prompt`); no verified flag blocks them
- **Timeout**: Panes auto-terminate after configurable timeout (default: 600s)

## Configuration

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `CCORCH_TIMEOUT` | `600` | Timeout in seconds per pane |
| `CCORCH_MAX_PANES` | `8` | Maximum total panes per session |
| `CCORCH_MAX_CHILDREN_D1` | `3` | Max concurrent children for Main Brain |
| `CCORCH_MAX_CHILDREN_D2` | `2` | Max concurrent grandchildren per Child |

## Moved to ccharness (0.9.0)

ccorch 0.4.0 also shipped an in-session agent catalog, hooks and a parallel
fan-out skill. ccorch 0.5.0 no longer ships any of them. If ccharness 0.9.0 or
later is installed, it provides the moved parts:

| Was in ccorch 0.4.0 | If ccharness is installed |
|---------------------|-----|
| 8 leaf agent types `ccorch:<type>` (web-research, web-refuter, log-distiller, worktree-worker, impl-verifier, pbr-reviewer, kb-integrator, knowledge-recorder) | `ccharness:<type>` |
| `/ccor-parallel` | `/ccharness:parallel-worktree` (cleanup only through worktree-sweep) |
| Catalog tier guard (`agent_gate.sh`) | ccharness's catalog tier guard |
| Agent ledger | `<main checkout>/.claude/ccharness/ledger.jsonl` |
| `url-extract` | Retired, not moved; see [DEC-005](docs/sdd/design/decisions/DEC-005.md#what-was-retired) |

**Migration**

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

## Optional Integrations

| Plugin | Integration |
|--------|-------------|
| [ccmemo](https://github.com/LevNas/ccmemo) | Persist discoveries via `/record-knowledge`, track plans via `/plan-task` |
| [ccresmon](https://github.com/LevNas/ccresmon) | Resource monitoring for spawned panes |

## For Contributors

ccorch follows the LevNas plugin conventions maintained in [claudecode-plugins/docs/development-guide.md](https://github.com/LevNas/claudecode-plugins/blob/main/docs/development-guide.md). Document placement and SKILL.md frontmatter rules are summarized below.

| Location | Purpose | Audience |
|----------|---------|----------|
| `README.md` | Plugin overview and usage | Users (humans) |
| `skills/<name>/SKILL.md` | Skill definition with required frontmatter (`name`/`description`/`license`/`allowed-tools`) | Claude Code |
| `hooks/` | Hook implementations and `hooks.json` | Claude Code |
| `scripts/` | Wrapper scripts (e.g. `ccorch-wrapper.sh`) | Runtime |
| `docs/sdd/` | SDD-style design documents (requirements/design/tasks) | Contributors (humans) |

Run the central linter from a claudecode-plugins checkout before sending a PR:

```bash
bash <path-to-claudecode-plugins>/scripts/lint-skills.sh .
```

## License

MIT
