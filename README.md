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
- [Auto mode](https://code.claude.com/docs/en/permission-modes) available to your sessions, for panes that run without prompts; without it, panes start in Manual mode and ask before most actions (see [Safety](#safety))

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
4. Results flow back up via `tmux wait-for` signals and file exchange under `/tmp/ccorch/<session_id>/`. Your session is signalled once the Main Brain has written its result, which is copied to `result.md` for you to read
5. Your session continues working in parallel — you're notified on completion

### Safety

- **Panes run in auto mode**: every pane starts with `--permission-mode auto`, not a permission bypass. Auto mode's classifier reviews actions; when it blocks one, a human may have to approve or redirect it in that pane. When auto mode is not available to the pane's session (a model that does not support it, auto mode turned off with the [`disableAutoMode`](https://code.claude.com/docs/en/settings-reference) setting, or turned off by Anthropic), Claude Code starts the pane in Manual mode and it prompts before most actions; a pane still waiting when `CCORCH_TIMEOUT` runs out is stopped; its status bar shows `auto mode on` only when auto mode is active. The start gate and the deny rules below apply in every mode
- **Start gate**: before `claude` starts, the wrapper refuses a pane when a limit is not a positive integer, when the depth is not 1-3 or does not follow from the parent's recorded depth, when a second Main Brain starts in one session, when the live ccorch panes would exceed `CCORCH_MAX_PANES`, or when the live children under one parent would exceed `CCORCH_MAX_CHILDREN_D1` / `_D2`. A refused child returns `status: refused` with the reason in its result file. The gate uses a portable `mkdir` lock (no `flock`, so it works on macOS). It bounds a model that uses the documented launch command; a process that rewrites its own environment or runs `claude` directly can escape it, and then the auto-mode classifier is the boundary
- **Deny rules**: every depth denies the common forms of `rm -rf`, force push, branch delete, `git reset --hard`, `git clean` and `sudo`; depth 2 and 3 also deny `git push`; depth 3 also denies the Agent tool and `tmux`. The Bash deny rules are not a security boundary: they miss other flag spellings, full paths, `sh -c`, aliases and the like. The boundaries are the classifier and the start gate. See [NFR-SEC-003](docs/sdd/requirements/nfr/security.md#nfr-sec-003-structural-depth-overflow-prevention) and [DEC-006](docs/sdd/design/decisions/DEC-006.md)
- **Timeout**: Panes auto-terminate after configurable timeout (default: 600s)

## Configuration

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `CCORCH_TIMEOUT` | `600` | Timeout in seconds per pane |
| `CCORCH_MAX_PANES` | `8` | Maximum live ccorch panes per session, Main Brain included (enforced by the start gate) |
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
