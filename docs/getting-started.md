# Getting Started

> 日本語版: [getting-started.ja.md](getting-started.ja.md)

Zero to first orchestration: lay out your repositories, install ccorch once at
user scope, delegate a first task to a catalog agent, and (optionally) fan out
parallel workers. The reference material — full catalog table, hook details,
configuration — stays in the [README](../README.md).

> **Status: Experimental.** Orchestration spawns multiple Claude Code agents
> and can consume significant tokens. Start small and watch your usage.

## What you end up with

- ccorch installed **once**, active in every repository you open: nine
  model-routed agent types, the enforcement hooks, and the `/ccor` /
  `/ccor-parallel` skills
- a first delegated task, with its launch recorded in the ledger
- a working sense of when to use subagents (the default) and when tmux panes
  are still the right tool (exactly three cases)

## Prerequisites

- [Claude Code](https://code.claude.com/docs/en/overview) CLI
- `jq` — recommended; the v2 hooks no-op without it
- `git` — worktree isolation (`/ccor-parallel`) requires a git repository
- `tmux` 1.8+ — pane mode (`/ccor`) only
- Optional: [ghq](https://github.com/x-motemen/ghq) for the clone layout below

## Step 1 — Lay out your repositories

Orchestration touches more of your filesystem than a plain session: pane mode
launches sessions whose working directory is pinned to a target repository,
and parallel workers operate in worktrees of the current one. A predictable
clone layout keeps every target path guessable — for you and for the
orchestrator.

We recommend the `~/src/<host>/<owner>/<repo>` layout. Plain `git clone`
works:

```bash
git clone https://github.com/you/app ~/src/github.com/you/app
```

[ghq](https://github.com/x-motemen/ghq) automates exactly this layout:

```bash
git config --global ghq.root '~/src'
ghq get github.com/you/app        # clones to ~/src/github.com/you/app
ghq list                          # every repository, one line each
```

ghq is optional — nothing in ccorch depends on it. It simply makes "which
repository does this pane/worker operate on" a path you can predict instead
of one you have to look up.

## Step 2 — Install at user scope

In any Claude Code session:

```
/plugin marketplace add LevNas/claudecode-plugins
/plugin install ccorch@levnas-plugins
```

When Claude Code asks for a scope, choose **User** — the plugin installs once
under `~/.claude/` and its agents, hooks, and skills are available in *every*
repository you open, which is what this guide assumes. The same install from
a shell, non-interactively:

```bash
claude plugin install ccorch@levnas-plugins --scope user
```

If the install summary says `Run /reload-plugins to activate`, do that (or
start a new session). Then verify:

- `/plugin list` shows ccorch as installed
- ask Claude "what ccorch agent types are available?" — it should list the
  nine `ccorch:*` catalog types from the [README](../README.md#agent-catalog)

**Team note** — to auto-enable ccorch for everyone who opens a shared project,
commit this to the project's `.claude/settings.json` (teammates still run the
`marketplace add` line once):

```json
{
  "enabledPlugins": {
    "ccorch@levnas-plugins": true
  }
}
```

## Step 3 — Delegate a first task

The v2 default needs no special command — with the plugin installed, Claude
Code sees the catalog types and you ask for delegation in plain words:

> Use ccorch:web-research to survey current approaches to X, with sources.

What just happened, and why it matters:

- the leaf ran on its **pinned model and effort** (sonnet, low effort) instead
  of silently inheriting your expensive main-session model;
- `agent_gate.sh` enforced the **parallel cap** (default 3) and the
  **model-routing guard**;
- the launch was appended to the **ledger** at `.claude/ccorch/ledger.jsonl`.

Verify the ledger after the first run:

```bash
tail -1 .claude/ccorch/ledger.jsonl | jq .
```

Format details: [ledger.md](ledger.md). If the file is missing, check that
`jq` is installed — the hooks are fail-open and no-op without it.

Pick leaves by cost: extraction and log-distilling run on haiku, research and
implementation on sonnet, adversarial refutation on sonnet at high effort —
see the [catalog table](../README.md#agent-catalog). If a leaf's output is not
good enough, re-run the same prompt one model tier up (at most once) — leaves
never judge their own quality.

## Step 4 — Fan out parallel workers (optional)

When you have several implementation tasks with **disjoint file ownership**,
`/ccor-parallel` fans them out to isolated worktree workers, then merges the
results in a dedicated integration worktree (never on main) and cleans up:

```
/ccor-parallel <task list with explicit file ownership per task>
```

Full procedure and the four orchestrator responsibilities:
[skills/ccor-parallel/SKILL.md](../skills/ccor-parallel/SKILL.md).

## When panes are still the right tool

Use `/ccor` (tmux pane mode) only for the three cases subagents cannot cover:

1. work that **writes to another repository**
2. work needing the target repo's **permission/hook enforcement layer**
3. work needing **real-time visual supervision**

```
/ccor <task description>
```

## Tuning

Defaults are conservative. The one knob most worth knowing on day one is
`CCORCH_MAX_PARALLEL` (default `3`) — lower it to `2` on a modest host, since
every concurrent agent is a running Claude Code instance. The full table of
environment variables is in the [README](../README.md#enforcement-hooks).

## Close the loop with ccmemo

An orchestrated session discovers more than one context window can retain —
and without persistence, the next session starts from zero. ccorch's sibling
plugin [ccmemo](https://github.com/LevNas/ccmemo) — same marketplace — is the
missing half, and two catalog types are built to plug directly into it:

- **`ccorch:knowledge-recorder`** drafts knowledge entries following ccmemo's
  `/record-knowledge` conventions. With ccmemo's scaffolding in place
  (`.claude/knowledge/`), a wave of orchestrated work can end with its
  discoveries drafted as ready-to-commit entries — you keep the decision of
  *what* gets recorded.
- **`ccorch:kb-integrator`** reads ten or more ccmemo entries and returns a
  cited synthesis — the "what do we already know about X" sweep that makes a
  grown knowledge base a pre-design asset instead of a pile.

And ccmemo gives the orchestrator memory in the other direction:
`/plan-task` persists a multi-wave plan across sessions, so a large
orchestration can run as resumable waves over days instead of one marathon;
`/recall-knowledge` lets any new session recover what earlier waves learned
before it spends tokens rediscovering it.

```
/plugin install ccmemo@levnas-plugins
```

Setup walkthrough on the ccmemo side:
[ccmemo docs/getting-started.md](https://github.com/LevNas/ccmemo/blob/main/docs/getting-started.md).
