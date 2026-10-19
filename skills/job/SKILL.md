---
name: job
description: Hand one task to a Claude session in its own tmux pane, working in a new worktree of another repository, and collect its result. Use when the task writes to another repository, must run under that repository's permission and hook layer, or needs watching in real time. Writes a cover note (where to work, the repository's rules, working files, what to return, what to do when stopped), starts the pane through ccorch's wrapper and waits for the result file.
license: MIT
allowed-tools: Bash, Read, Write
---

# job

Hand one task to a pane. The pane does the task itself, in a worktree of the target repository, and writes a result file. Use `/ccor` instead when a task should be split across several panes.

What the pane must do is split in two:

- **Set by the wrapper, not asked for in text.** The pane runs `claude --worktree <name>` in the target repository, so it starts in a new worktree on its own branch instead of the main checkout. That sets where it starts; it does not stop a later `git -C <main checkout> ...` (the system prompt and the auto-mode classifier are what stand against that). It runs in auto mode with ccorch's deny rules, including the usual forms of `tmux`, so it does not start panes the usual way.
- **Written in the cover note.** Everything else: the repository's rules, where working files go, what to return, what to do when stopped. A ban written in text does not hold on its own: a pane told not to use `rm` still ran `rm -rf` and stopped at the ask rule. When something must not happen, rely on a deny rule, a hook or the worktree, and use the cover note to say what to do instead.

No real job pane has been run yet (see `docs/sdd/design/decisions/DEC-007.md`). Watch the first ones in their pane.

## Steps

### 1. Check that a pane is the right tool

Use a pane only for one of these:

1. The task writes to another repository
2. It must run under the target repository's permission and hook layer
3. It needs watching in real time

Otherwise, stop and suggest a subagent (or the current session): a pane costs a whole session.

Also check:

- tmux 3.0 or later is reachable (`tmux -V`, `tmux list-sessions`). The session may be outside tmux (a background job has no `$TMUX`); the launcher then adds the window to a session tmux picks.
- Whether the target repository ignores `.claude/tmp/` (`git -C <repository> check-ignore -q .claude/tmp/x` exits 0 when it does). If it does not, say so in the cover note's "Working files" section.
- The target is the top directory of a git repository. Claude Code creates the worktree from it; where the new branch starts follows Claude Code's `worktree.baseRef` setting for that repository (with `head`, the main checkout's current commit), so check that the main checkout is where the work should start.

### 2. Write the content

The content says what the task is. Do not repeat what is already written down: write the state into an issue or a file and point to it.

- If this session has an `arc-handoff` skill (a project skill; ccharness scaffolds one), run it first, then point to where it wrote.
- Otherwise write the same three things yourself: pointers (issue, PR, files) instead of copies, the next skill to use (by name, or "none"), and nothing secret (replace credentials and private values with placeholders such as `<token>`).

### 3. Write the cover note

Write the cover note and the content to one file outside the target repository (for example the session's scratchpad), with the Write tool. Fill every section; a section you leave empty is a decision you left to the pane.

```markdown
# Cover note

## Where you work
- Repository: <absolute path>
- Worktree: <name>. The wrapper starts you with `claude --worktree <name>`; you are already in it.
  Work, commit and run commands there only. Never switch branches in the repository's main checkout.

## The repository's rules
- Follow the repository's CLAUDE.md and `.claude/rules/`.
- <pitfalls you know for this repository: a commit hook that stages more than you meant, a test that needs a setting, ...>
- <for a public repository: commit messages in English, no attribution lines, no private names or paths>
- Left to the user: <merging, applying the change to the live system (for example `chezmoi apply`), deleting branches, ...>

## Working files
- Put temporary files in `.claude/tmp/` inside the worktree. Leave them there; do not delete them
  (an ask rule on `rm` stops the pane). The caller cleans up.
- Never commit them: add the files you changed by name, not with `git add -A` or `git add .`.
  <if the repository does not ignore `.claude/tmp/`, say so here>.

## What to return
- Write the result file in the format your instructions give (Summary, Evidence, Not tested,
  Branch and PR, Left behind).
- <what this task must report besides that: the PR number, a measurement, ...>

## When you are stopped
- If an action needs a human's approval, or something here cannot be done as written, do not try
  another route. Write the result file with `status: partial` and say where you stopped.

# Content

<pointers and the next skill, from step 2>
```

### 4. Start the pane

First find the scripts directory, once: `${CLAUDE_PLUGIN_ROOT}/scripts` when `CLAUDE_PLUGIN_ROOT` is set; otherwise the "Base directory for this skill" shown when this skill loaded, followed by `/../../scripts`. Write it as an absolute path in the commands below.

Pick a worktree name for the task (letters, digits, `.`, `_`, `-`, not starting with `.` or `-`, no `..`, at most 64 characters; for example `fix-gates-file`). Then run, as one command:

```bash
bash <scripts>/ccorch-job.sh <repository> <worktree name> <task file> [timeout seconds]
```

- The timeout is the fourth argument, default 3600 seconds. `CCORCH_TIMEOUT` in your environment is not read; `CCORCH_MAX_PANES` is passed on when set.
- The script prints `work_dir=`, `channel=` and `pane=`; keep them.
- It exits 2 without starting anything when an input is wrong: a bad worktree name, a worktree of that name already in `<repository>/.claude/worktrees/`, a repository path with `#`, a task over 100000 bytes, tmux older than 3.0. Fix the input; do not work around the check.
- Exit 0 means tmux opened the window, not that the job runs. The wrapper's start gate may still refuse it (the pane limit, for example); the window then closes at once and the refusal reason is in the result, with `status: refused`. Always wait for and read the result.

### 5. Wait in the background

```bash
bash <scripts>/ccorch-wait.sh <work_dir> <channel>
```

Run it with `run_in_background: true` and keep working. It prints `result=<path>` when the result exists. While you wait:

- The pane may stop at a permission prompt; nothing arrives until it writes its result or the timeout runs out. If the wait is long, tell the user to look at the pane (`pane=` from step 4).
- Do not answer the pane's prompts from this session; they are the user's.

### 6. Report

Read the result file and `<work_dir>/status.md`. Tell the user:

- The `status:` (`success`, `partial`, or what the wrapper wrote: `refused`, `error`, `incomplete`, `timeout`) and the Summary.
- The branch and PR, and what is under Not tested. Do not claim more than the Evidence section shows.
- What is left behind.

### 7. Clean up, on the user's word

Ask before each of these:

- Close the pane: `tmux kill-pane -t <pane>`. The session stays in Claude Code's session list.
- Remove the worktree and branch after the PR is merged. Find them with `git -C <repository> worktree list` (the worktree is under `<repository>/.claude/worktrees/<name>`), then `git -C <repository> worktree remove <path>` and `git -C <repository> branch -d <branch>`, never with `--force` or `-D`. Move anything you want to keep out of `.claude/tmp/` first: `git worktree remove` deletes ignored files without asking, and refuses while untracked files are there; then show the user the files and ask.
- The work directory (`work_dir=`) holds the task copy and the result files. Delete it after you have reported, if the user agrees.

## Related

- `/ccor`: several panes, with a Main Brain that splits the task.
- The wrapper's job mode: `CCORCH_MODE=job` and `CCORCH_WORKTREE` in `scripts/ccorch-wrapper.sh`; the design is in `docs/sdd/design/decisions/DEC-007.md`.
