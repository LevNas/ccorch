---
name: ccor-parallel
description: Fan out file-ownership-disjoint implementation tasks to parallel worktree-isolated subagents, then preserve artifacts, merge in an integration worktree, and clean up. Implements the four orchestrator responsibilities of ccorch v2 (origin pinning, collection, integration merge, capture preservation) on top of the harness's native worktree isolation.
license: MIT
allowed-tools: Bash, Read, Grep, Glob, Agent
---

# ccor-parallel

Parallel implementation across isolated git worktrees, using the bundled
`ccorch:worktree-worker` agent type.

## Division of labor

The harness already provides worktree creation, branch creation
(`worktree-agent-<id>`), locking (owned by this session, released on agent
completion), and automatic cleanup of **unchanged** worktrees. Do not
reimplement any of that. This skill adds only the four orchestrator
responsibilities: **pin the origin, preserve captures, merge, clean up**.

## When to Use

- Two or more implementation tasks in THIS repository with **disjoint file
  ownership** (no shared files between tasks).
- Each task is closed and mechanically specified (spec, ownership list,
  acceptance criteria). SDD-style task decompositions are the ideal input.

Do NOT use when tasks share files (serialize those), when the work needs
design judgment mid-flight (keep it in the main session), or for cross-repo
writes (pane conditions apply — see `/ccor`).

**Never run this from inside a worktree-isolated session**: such sessions
cannot run git against the shared checkout. Orchestrate from the main
checkout.

## Phase 0 — Pin the origin

With `worktree.baseRef: head` (project setting), the orchestrator's cwd HEAD
determines the fan-out base of every spawned worktree.

```bash
git rev-parse --abbrev-ref HEAD && git rev-parse HEAD   # record as BASE
git status --short                                       # expect clean
grep -rs '"baseRef"' .claude/settings.json .claude/settings.local.json
```

- Record BASE in your working notes; every later phase references it.
- Do not `cd` elsewhere or move HEAD between launches — all workers of one
  wave must share the same base.
- With `baseRef: fresh` (default), the base is origin's default branch;
  fetch first if that is intended, or set the project to `head` for
  local-stacked work.

## Phase 1 — Fan out in waves

- At most `CCORCH_MAX_PARALLEL` (default 3) workers at once; the gate hook
  enforces this. Split excess tasks into waves.
- Spawn `ccorch:worktree-worker` per task, background, with this prompt
  shape:

```
Task: <closed spec>
Ownership — you may modify ONLY these files: <explicit list>
Acceptance criteria: <list>
Commit message to use: <message>
Verification commands to run: <commands or "none">
```

(The worker's own definition carries the hard rules: no `.claude/` writes,
explicit-path `git add` only, no push, no branch switching.)

- Wait for completion notifications; do not poll. Record thread→agentId
  pairs; the ledger hook records them automatically in
  `.claude/ccorch/ledger.jsonl` — cross-check with `ListAgents` if in doubt.

## Phase 2 — Preserve captures (BEFORE any removal)

For each completed worker with changes, its worktree
(`.claude/worktrees/agent-<id>`) and branch survive; unchanged workers are
already auto-cleaned.

1. List untracked artifacts in the worker worktree:
   `git -C <worktree> status --porcelain` (look for session-capture files,
   e.g. ccmemo `context-*.md` under `.claude/tasks/`).
2. Move captures to the main checkout's `.claude/tasks/<slug>/`, appending a
   worker suffix to the filename to avoid same-second collisions:
   `context-<ts>.md` → `context-<ts>-<worker>.md`.
3. Decide explicitly about any other untracked file; removal destroys it.

## Phase 3 — Integration merge

1. Verify each worker's report: the commit exists and only owned files
   changed:
   `git diff --name-only BASE..<branch>` — abort integration of a branch
   that touches `.claude/` or files outside its ownership list.
2. Create an integration worktree off BASE — never merge on main:
   `git worktree add <path> -b integration/<slug> BASE`
3. Merge each worker branch with `--no-ff` (symmetric history):
   `git -C <path> merge --no-ff <branch>`
4. Disjoint ownership means conflicts should not occur. If one does, stop
   and re-examine the ownership split — do not resolve silently.
5. Optionally spawn `ccorch:impl-verifier` against the integration worktree
   before proceeding.

## Phase 4 — Clean up

Only after the merge:

```bash
git merge-base --is-ancestor <branch> integration/<slug>   # must succeed
git worktree remove --force .claude/worktrees/agent-<id>   # untracked leftovers block a plain remove
git branch -D <branch>
```

The `--is-ancestor` check is the deterministic guard that the branch's
commits are contained in the integration branch; never delete a branch that
fails it. The integration branch itself is handed to the user (PR or manual
merge) — this skill never touches main and never pushes.

## Escalation (deterministic)

If a worker's output fails acceptance, re-run the same prompt with the model
one tier up (`sonnet` → `opus`), at most once, and record the escalation in
your report. The orchestrator decides this — never ask a leaf to judge its
own quality.

## Report to the user

- BASE commit, wave layout, per-task: branch, commit, verify result,
  deviations.
- Captures preserved (paths), branches merged, integration branch name.
- Ledger location for resume handles.
