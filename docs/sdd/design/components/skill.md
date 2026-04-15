# Component: SKILL.md (`/ccor`)

## Purpose

Entry point for orchestration. When the user invokes `/ccor`, this skill instructs Claude Code to:
1. Generate a session and prepare the work directory
2. Launch a Main Brain in a new tmux pane
3. Set up background completion monitoring
4. Return control to the user

## Skill Invocation

```
/ccor <task description>
```

Example:
```
/ccor Refactor the authentication module — extract middleware, add tests, update docs
```

## SKILL.md Structure

The SKILL.md file contains:

### 1. Skill Metadata

```markdown
# ccor

Orchestrate complex tasks across multiple tmux panes with 3-level depth control.
```

### 2. Precondition Checks

Before launching orchestration, the skill verifies:

| Check | Method | Failure Action |
|-------|--------|----------------|
| tmux available | `command -v tmux` | Error: "tmux is required" |
| Inside tmux session | `$TMUX` is set | Error: "Must run inside tmux" |
| Not already orchestrating | `$CCORCH_DEPTH` is unset | Error: "Already inside orchestration" |

### 3. Session Initialization

```bash
SESSION_ID=$(date +%s)
WORK_DIR="/tmp/ccorch/${SESSION_ID}"
mkdir -p "$WORK_DIR"
CHANNEL="CCORCH_DONE_${SESSION_ID}"
```

### 4. Main Brain Launch

```bash
tmux new-window -n "ccorch-${SESSION_ID}" \
  "CCORCH_DEPTH=1 \
   CCORCH_SESSION_ID=${SESSION_ID} \
   CCORCH_PARENT_CHANNEL=${CHANNEL} \
   CCORCH_WORK_DIR=${WORK_DIR} \
   CCORCH_TIMEOUT=${CCORCH_TIMEOUT:-600} \
   CCORCH_MAX_PANES=${CCORCH_MAX_PANES:-8} \
   bash /path/to/ccorch-wrapper.sh '${TASK}'"
```

### 5. Background Completion Wait

The skill instructs Claude Code to:
1. Run `tmux wait-for $CHANNEL` with `run_in_background: true`
2. After signal reception, read `$WORK_DIR/result.md`
3. Present summary to the user

### 6. System Prompt for Main Brain

```
You are CCORCH Main Brain (DEPTH=1).

## Your Role
- Analyze the given task and decompose it into subtasks
- Create child panes (DEPTH=2) for independent subtasks
- Wait for children to complete and aggregate results
- Write final results to $CCORCH_WORK_DIR/result.md

## Rules
- Maximum panes: $CCORCH_MAX_PANES total across all depths
- No destructive git operations (push --force, reset --hard, branch -D)
- Signal parent when done: tmux wait-for -S $CCORCH_PARENT_CHANNEL

## Child Pane Creation
To create a child pane, use the wrapper script:
  bash scripts/ccorch-wrapper.sh '<child task>'

## Environment
- CCORCH_DEPTH=1
- CCORCH_SESSION_ID=<id>
- CCORCH_WORK_DIR=<path>
- CCORCH_TIMEOUT=<seconds>
```

## ccmemo Integration Point

If ccmemo is available (detected by checking if `/record-knowledge` skill exists):
- Include in system prompt: "You have ccmemo available. Use /record-knowledge for important discoveries."
- Include in system prompt: "Use /plan-task to track orchestration progress."

If not available:
- Omit ccmemo references from system prompt

## Worktree Decision

The system prompt instructs Main Brain to decide on `--worktree` usage:

```
## Worktree
If the task involves code changes across multiple files that could conflict,
use --worktree (-w) when creating child panes. For research/analysis tasks,
worktree is unnecessary.
```
