# Getting Started

> 日本語版: [getting-started.ja.md](getting-started.ja.md)

Zero to first pane run: lay out your repositories, install ccorch once at
user scope, and launch your first `/ccor` task. The reference material —
configuration, safety — stays in the [README](../README.md).

> **Status: Experimental.** Orchestration spawns multiple Claude Code sessions
> and can consume significant tokens. Start small and watch your usage.

ccorch does one thing: it splits work into **separate tmux panes**. Work
distributed inside a single session (leaf agents, parallel worktree fan-out,
agent records) is not part of ccorch since 0.5.0; see
[Moved to ccharness](../README.md#moved-to-ccharness-090).

## What you end up with

- ccorch installed **once**, with the `/ccor` skill available in every
  repository you open
- a first `/ccor` run in a tmux pane
- a working sense of the three cases where panes are the right tool

## Prerequisites

- [Claude Code](https://code.claude.com/docs/en/overview) CLI
- `tmux` 1.8+ — required; `/ccor` must run inside a tmux session
- Optional: [ghq](https://github.com/x-motemen/ghq) for the clone layout below

## Step 1 — Lay out your repositories

Pane mode launches sessions whose working directory is pinned to a target
repository. A predictable clone layout keeps every target path guessable —
for you and for the Main Brain.

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

ghq is optional — nothing in ccorch depends on it.

## Step 2 — Install at user scope

In any Claude Code session:

```
/plugin marketplace add LevNas/claudecode-plugins
/plugin install ccorch@levnas-plugins
```

When Claude Code asks for a scope, choose **User** — the plugin installs once
under `~/.claude/` and its skill is available in *every* repository you open.
The same install from a shell, non-interactively:

```bash
claude plugin install ccorch@levnas-plugins --scope user
```

If the install summary says `Run /reload-plugins to activate`, do that (or
start a new session). Then verify that `/plugin list` shows ccorch as
installed.

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

## Step 3 — Run your first pane task

Start (or attach to) a tmux session, start Claude Code inside it, and run:

```
/ccor <task description>
```

A Main Brain pane opens beside your session, decomposes the task and delegates
to Child panes. Your own session stays free; you are notified when the Main
Brain signals completion, and the results are read from
`/tmp/ccorch/<session_id>/`.

Use panes only for these three cases:

1. work that **writes to another repository**
2. work that must run under the target repository's **permission/hook layer**
3. work that needs **real-time visual supervision**

Anything else is cheaper in one session.

## Configuration

The knobs are the `CCORCH_*` environment variables in the
[README](../README.md#configuration). The one most worth knowing on day one is
`CCORCH_MAX_CHILDREN_D1` (default `3`): every pane is a running Claude Code
instance, so lower it on a modest host.

The pane and children limits are enforced by the wrapper before a pane starts.
A pane over a limit does not run; it returns `status: refused` with the reason.

Panes run in auto mode (`--permission-mode auto`), not with a permission
bypass. If the auto-mode classifier blocks an action, that pane may wait for
you: look at the pane, then approve or redirect it. Destructive commands are
denied by rule, and `git push` only works in the Main Brain pane; these Bash
rules cover the usual command form and are not a security boundary.

## Close the loop with ccmemo

A pane run discovers more than one context window can retain — and without
persistence, the next session starts from zero. ccorch's sibling plugin
[ccmemo](https://github.com/LevNas/ccmemo) — same marketplace — is the
missing half:

- `/record-knowledge` persists what the run discovered, so you keep the
  decision of *what* gets recorded.
- `/plan-task` persists a multi-step plan across sessions, so a large task can
  run as resumable steps over days instead of one marathon.
- `/recall-knowledge` lets any new session recover what earlier runs learned
  before it spends tokens rediscovering it.

```
/plugin install ccmemo@levnas-plugins
```

Setup walkthrough on the ccmemo side:
[ccmemo docs/getting-started.md](https://github.com/LevNas/ccmemo/blob/main/docs/getting-started.md).
