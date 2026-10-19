---
name: job
description: Hand one task to a Claude session in its own tmux pane, working in a new worktree of another repository, and collect its result. Use when the task writes to another repository, must run under that repository's permission and hook layer, or needs watching in real time. Writes a cover note (where to work, the repository's rules, working files, what to return, what to do when stopped), starts the pane through ccorch's wrapper and waits for the result file.
license: MIT
allowed-tools: Bash, Read, Write
---

# job

Hand one task to a pane. The pane does the task itself, in a worktree of the target repository, and writes a result file. Use `/ccor` instead when a task should be split across several panes.

What the pane must do is split in two:

- **Set by the wrapper, not asked for in text.** The pane runs `claude --worktree <name>` in the target repository, so its session is isolated in a new worktree and cannot switch the repository's main checkout. It runs in auto mode with ccorch's deny rules, and `tmux` is denied, so it starts no panes.
- **Written in the cover note.** Everything else: the repository's rules, where working files go, what to return, what to do when stopped. A ban written in text does not hold on its own: a pane told not to use `rm` still ran `rm -rf` and stopped at the ask rule. When something must not happen, rely on a deny rule, a hook or the worktree, and use the cover note to say what to do instead.

## Steps

### 1. Check that a pane is the right tool

Use a pane only for one of these:

1. The task writes to another repository
2. It must run under the target repository's permission and hook layer
3. It needs watching in real time

Otherwise, stop and suggest a subagent (or the current session): a pane costs a whole session.

Also check:

- tmux is reachable (`tmux list-sessions`). The session may be outside tmux (a background job has no `$TMUX`); the launcher then adds the window to a session tmux picks.
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

Pick a worktree name for the task (letters, digits, `.`, `_`, `-`; for example `fix-gates-file`). Then run, as one command:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/ccorch-job.sh" <repository> <worktree name> <task file> [timeout seconds]
```

If `CLAUDE_PLUGIN_ROOT` is not set, the script is at `../../scripts/ccorch-job.sh` from this skill's directory. The timeout defaults to 3600 seconds. The script prints `work_dir=`, `channel=` and `pane=`; keep them.

The wrapper's start gate may refuse the pane (a bad worktree name, the pane limit); the refusal arrives as the result, with `status: refused` and the reason.

### 5. Wait in the background

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/ccorch-wait.sh" <work_dir> <channel>
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
- Remove the worktree and branch after the PR is merged, from the target repository, without `--force`. Move anything you want to keep out of `.claude/tmp/` first: `git worktree remove` deletes ignored files without asking.

## Related

- `/ccor`: several panes, with a Main Brain that splits the task.
- The wrapper's job mode: `CCORCH_MODE=job` and `CCORCH_WORKTREE` in `scripts/ccorch-wrapper.sh`; the design is in `docs/sdd/design/decisions/DEC-007.md`.
