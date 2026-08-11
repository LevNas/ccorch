# ccorch

> **Status: Experimental** — This plugin is in early development. Each orchestration session spawns multiple Claude Code instances, which can consume significant tokens. Use with caution and monitor your usage.

Orchestration plugin for Claude Code. Since v2 (0.3.0) the default substrate
is Claude Code's native subagents — background agents, SendMessage resume,
and worktree isolation — with a bundled, model-routed agent catalog and
enforcement hooks. tmux panes remain for exactly three cases (see below).

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI
- `jq` (recommended — the v2 hooks no-op without it)
- [tmux](https://github.com/tmux/tmux) 1.8+ (pane mode `/ccor` only)

## Installation

```bash
# Add the marketplace
/plugin marketplace add LevNas/claudecode-plugins

# Install the plugin
/plugin install ccorch@levnas-plugins
```

Step-by-step walkthrough — repository layout, user scope, first delegation,
ccmemo integration: [docs/getting-started.md](docs/getting-started.md)
([日本語](docs/getting-started.ja.md)).

## v2: Subagent Orchestration (default)

### Agent catalog

Nine leaf agent types ship with `model` and `effort` pinned in frontmatter,
so "forgot to specify a model" (which silently inherits your expensive
main-session model) becomes "picked a type with the right cost". None of
them has the Agent tool — leaves cannot spawn sub-leaves (depth control).

| Type | Job | Model | Effort |
|------|-----|-------|--------|
| `ccorch:web-research` | Web research over 3+ sources, cited + freshness-dated | sonnet | low |
| `ccorch:url-extract` | Pure extraction from given URLs | haiku | low |
| `ccorch:log-distiller` | Distill tests/builds/logs to the lines that matter | haiku | low |
| `ccorch:worktree-worker` | Mechanical implementation + commit in an isolated worktree | sonnet | low |
| `ccorch:impl-verifier` | Acceptance-criteria verification, evidence per criterion | sonnet | medium |
| `ccorch:pbr-reviewer` | Perspective-parameterized review (`[LGTM]/[CONCERN]/[GAP]`) | sonnet | medium |
| `ccorch:kb-integrator` | Integrate 10+ knowledge entries into a cited synthesis | sonnet | medium |
| `ccorch:knowledge-recorder` | Draft KB entries per host conventions (ccmemo style) | sonnet | medium |
| `ccorch:web-refuter` | Adversarial refutation of decision-grade claims | sonnet | high |

Escalation is deterministic: on insufficient quality, the orchestrator
re-runs the same prompt one model tier up (at most once) — leaves never
judge their own quality.

### Enforcement hooks

| Hook | Event | What it does |
|------|-------|--------------|
| `agent_gate.sh` | PreToolUse (Agent) | Denies spawns beyond the parallel cap; denies model overrides above a catalog type's tier (+1 allowed for escalation); denies non-catalog spawns with no explicit model |
| `ledger_record.sh` | PostToolUse (Agent) | Appends launch records (thread → agentId) to `.claude/ccorch/ledger.jsonl` |
| `ledger_stop.sh` | SubagentStop | Appends stop records (balances the running count) |

All hooks are fail-open: missing `jq`, malformed input, or an unreadable
ledger never blocks a session. Ledger format: [docs/ledger.md](docs/ledger.md).

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `CCORCH_GATE` | `on` | `off` disables both guards |
| `CCORCH_MODEL_GUARD` | `on` | `off` disables only the model-routing guard |
| `CCORCH_MAX_PARALLEL` | `3` | Concurrent agent cap (host-resource guard) |
| `CCORCH_GATE_EXEMPT_TYPES` | `claude-code-guide,statusline-setup` | Types exempt from the model guard |

### `/ccor-parallel`

Fans out file-ownership-disjoint tasks to parallel `worktree-worker` agents,
then executes the four orchestrator responsibilities the harness does not
cover: **origin pinning** (with `worktree.baseRef: head`, the orchestrator's
HEAD decides every worker's base), **capture preservation** (session-capture
files die with the worktree — move them out first), **integration merge**
(dedicated worktree, `--no-ff`, never on main), and **cleanup** (`worktree
remove --force` + branch deletion, only after a `merge-base --is-ancestor`
check). See [skills/ccor-parallel/SKILL.md](skills/ccor-parallel/SKILL.md).

### When panes are still the right tool

Use `/ccor` (pane mode, below) only for:

1. Work that **writes to another repository** (subagents cannot)
2. Work needing the target repo's **permission/hook enforcement layer**
3. Work needing **real-time visual supervision**

Design rationale: [docs/sdd/design/decisions/DEC-004.md](docs/sdd/design/decisions/DEC-004.md).

## Pane Mode: `/ccor`

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
4. Results flow back up via `tmux wait-for` signals and file exchange
5. Your session continues working in parallel — you're notified on completion

### Safety

- **Tool restrictions**: Each depth level has progressively stricter `--allowedTools`
- **Depth limit**: Grandchildren (DEPTH=3) cannot create new panes (`Agent` tool disabled)
- **Bash restrictions**: Destructive commands (`git push --force`, `rm -rf`) are pattern-blocked
- **Timeout**: Panes auto-terminate after configurable timeout (default: 600s)

## Configuration

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `CCORCH_TIMEOUT` | `600` | Timeout in seconds per pane |
| `CCORCH_MAX_PANES` | `8` | Maximum total panes per session |
| `CCORCH_MAX_CHILDREN_D1` | `3` | Max concurrent children for Main Brain |
| `CCORCH_MAX_CHILDREN_D2` | `2` | Max concurrent grandchildren per Child |

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
| `agents/` | Bundled subagent definitions (model/effort pinned in frontmatter) | Claude Code |
| `hooks/` | Hook implementations and `hooks.json` | Claude Code |
| `scripts/` | Wrapper scripts (e.g. `ccorch-wrapper.sh`) | Runtime |
| `docs/sdd/` | SDD-style design documents (requirements/design/tasks) | Contributors (humans) |

Run the central linter from claudecode-plugins before sending a PR:

```bash
bash ~/src/github.com/LevNas/claudecode-plugins/scripts/lint-skills.sh ~/src/github.com/LevNas/ccorch
```

## License

MIT
