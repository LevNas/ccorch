# Design

> This document assumes implementation by AI agents (Claude Code, etc.).
> Sections clearly distinguish "explicitly specified" from "unknown/to-be-confirmed" information.

## Explicitly Specified Information

- [x] Technology: tmux (wait-for signaling), Claude Code CLI (interactive, `--permission-mode auto`, `--disallowedTools`, `--append-system-prompt`)
- [x] Architecture: 3-level tmux pane hierarchy with environment variable depth propagation
- [x] Communication: `tmux wait-for` signals + file-based data exchange (`/tmp/ccorch/`)
- [x] Safety: a start gate in the wrapper that enforces the depth, pane and children limits, per-depth `--disallowedTools` rules, panes in auto mode, and system prompt guard rails per depth (see Security Considerations and [DEC-006](decisions/DEC-006.md))
- [x] Plugin format: Claude Code plugin (`.claude-plugin/plugin.json`, skills, hooks)
- [x] Distribution: claudecode-plugins marketplace

## No Unknown Information

All design decisions have been confirmed with the user during the requirements phase.

---

## Architecture Overview

```
User's Claude Code Session
  │
  │ /ccor "Refactor API layer"
  │
  ├── 1. Generate session ID, create /tmp/ccorch/<id>/
  ├── 2. tmux new-window → Main Brain (DEPTH=1)
  ├── 3. run_in_background: tmux wait-for CCORCH_DONE_<id>
  └── 4. User continues parallel work
           │
Main Brain (DEPTH=1)
  │
  ├── Analyze task, decompose into subtasks
  ├── tmux split-pane → Child A (DEPTH=2)
  ├── tmux split-pane → Child B (DEPTH=2)
  ├── Wait for children via tmux wait-for
  ├── Close children's panes, write its own result file (Write tool)
  └── Stop hook: copy → /tmp/ccorch/<id>/result.md, then tmux wait-for -S CCORCH_DONE_<id>
           │
Child (DEPTH=2)
  │
  ├── Optionally create Grandchild (DEPTH=3)
  ├── Execute assigned task
  ├── Write results → /tmp/ccorch/<id>/child-<n>.md
  └── tmux wait-for -S <parent_channel>
           │
Grandchild (DEPTH=3)
  │
  ├── Cannot create new panes (by system prompt; see the flag table in Security Considerations)
  ├── Execute assigned task only
  ├── Write results → /tmp/ccorch/<id>/grandchild-<n>.md
  └── tmux wait-for -S <parent_channel>
```

## Components

| Component | Purpose | Details |
|-----------|---------|---------|
| SKILL.md | `/ccor` skill definition — orchestration entry point | [Details](components/skill.md) @components/skill.md |
| Wrapper Script | Child pane launcher with signal guarantee | [Details](components/wrapper-script.md) @components/wrapper-script.md |
| Result Aggregator | Collects and summarizes child results | [Details](components/result-aggregator.md) @components/result-aggregator.md |

## Technical Decisions

| ID | Decision | Status | Details |
|----|----------|--------|---------|
| DEC-001 | tmux wait-for for signaling (not polling) | Approved | [Details](decisions/DEC-001.md) @decisions/DEC-001.md |
| DEC-002 | Environment variables for depth propagation | Approved | [Details](decisions/DEC-002.md) @decisions/DEC-002.md |
| DEC-003 | /tmp/ for result storage (not .claude/) | Approved | [Details](decisions/DEC-003.md) @decisions/DEC-003.md |
| DEC-004 | v2 subagent-default hybrid; three conditions for panes | Partially superseded by DEC-005 (pane conditions stand) | [Details](decisions/DEC-004.md) @decisions/DEC-004.md |
| DEC-005 | ccorch is pane orchestration only; in-session distribution moved to ccharness | Accepted | [Details](decisions/DEC-005.md) @decisions/DEC-005.md |
| DEC-006 | Panes run in auto mode; limits enforced by a start gate | Accepted (complements DEC-002) | [Details](decisions/DEC-006.md) @decisions/DEC-006.md |

## Security Considerations

### Depth-Based Tool Flags

What the wrapper passes (`scripts/ccorch-wrapper.sh`), and what `claude --help` says about each flag:

| Flag | DEPTH 1 | DEPTH 2 | DEPTH 3 |
|------|---------|---------|---------|
| `--permission-mode` | `auto` | `auto` | `auto` |
| `--disallowedTools` | `Bash(rm -rf *)` `Bash(rm -fr *)` `Bash(rm -Rf *)` `Bash(rm -r -f *)` `Bash(rm -f -r *)` `Bash(rm -r --force *)` `Bash(rm --recursive *)` `Bash(git push --force *)` `Bash(git push *--force*)` `Bash(git push -f *)` `Bash(git push * -f*)` `Bash(git push * +*)` `Bash(git push *--delete*)` `Bash(git push * :*)` `Bash(git branch -D *)` `Bash(git reset --hard *)` `Bash(git clean *)` `Bash(sudo *)` | the DEPTH 1 rules, `Bash(git push *)` and `Bash(git -C * push*)` | the DEPTH 2 rules, `Agent` and `Bash(tmux *)` |
| `--append-system-prompt` | yes | yes | yes |

The permission bypass flag and `--allowedTools` are not passed: allow rules have no effect under the bypass, while deny rules hold in every mode. The Bash deny rules catch the usual command form only and are not a security boundary; the boundaries are the auto-mode classifier and the start gate, which refuses a pane over the depth, pane or children limits. See [NFR-SEC-003](../requirements/nfr/security.md#nfr-sec-003-structural-depth-overflow-prevention) and [DEC-006](decisions/DEC-006.md).

What the wrapper runs (interactive Claude Code; the task is not passed with `-p`):

```bash
# DEPTH 1
claude --permission-mode auto \
  --disallowedTools 'Bash(rm -rf *)' 'Bash(rm -fr *)' 'Bash(rm -Rf *)' 'Bash(rm -r -f *)' \
                    'Bash(rm -f -r *)' 'Bash(rm -r --force *)' 'Bash(rm --recursive *)' \
                    'Bash(git push --force *)' 'Bash(git push *--force*)' \
                    'Bash(git push -f *)' 'Bash(git push * -f*)' 'Bash(git push * +*)' \
                    'Bash(git push *--delete*)' 'Bash(git push * :*)' \
                    'Bash(git branch -D *)' 'Bash(git reset --hard *)' 'Bash(git clean *)' \
                    'Bash(sudo *)' \
  --append-system-prompt "$SYSTEM_PROMPT"

# DEPTH 2: the same, with 'Bash(git push *)' and 'Bash(git -C * push*)' added to --disallowedTools
# DEPTH 3: DEPTH 2, with 'Agent' and 'Bash(tmux *)' added to --disallowedTools

# Task delivery, started in the background before claude launches:
sleep 3; tmux load-buffer "$TASK_FILE"; tmux paste-buffer -t "$CURRENT_PANE"; sleep 0.5; tmux send-keys -t "$CURRENT_PANE" Enter
```

### Guard Rail System Prompts

Injected via `--append-system-prompt` at each depth:

| Depth | Key Rules |
|-------|-----------|
| 1 | Can delegate to children. No destructive git ops. Aggregate results before signaling parent. |
| 2 | Can delegate to grandchildren. No destructive git ops. Write results to CCORCH_WORK_DIR. |
| 3 | Must not create panes (Agent and the usual tmux forms are denied). Execute assigned task only. Write results to CCORCH_WORK_DIR. |

## Error Handling Strategy

### Timeout Mechanism

```bash
# Timeout watchdog (runs in parallel with tmux wait-for)
(
  sleep ${CCORCH_TIMEOUT:-600}
  # Write timeout result file
  echo "---\nstatus: timeout\n---" > "$CCORCH_WORK_DIR/child-$N.md"
  tmux wait-for -S "$CHANNEL"
) &
WATCHDOG_PID=$!

# Main wait
tmux wait-for "$CHANNEL"
kill $WATCHDOG_PID 2>/dev/null
```

### Abnormal Termination Recovery

The wrapper script uses `trap` to guarantee signal delivery:

```bash
trap 'echo "---\nstatus: error\n---" > "$RESULT_FILE"; tmux wait-for -S "$CHANNEL"' EXIT
```

### Result File Atomic Write

Write to temporary file, then rename:

```bash
cat > "${RESULT_FILE}.tmp" <<EOF
---
status: success
---
# Results
...
EOF
mv "${RESULT_FILE}.tmp" "$RESULT_FILE"
```

## File Structure

```
ccorch/
├── .claude-plugin/
│   └── plugin.json              # Plugin metadata (v0.6.3)
├── hooks/
│   ├── hooks.json               # Stop hook registration
│   └── stop_signal.sh           # Signals the parent pane on Stop (the Main Brain: once its result exists)
├── skills/
│   └── ccor/
│       └── SKILL.md             # Skill definition
├── scripts/
│   ├── ccorch-wrapper.sh        # Child pane wrapper script
│   ├── ccorch-lib.sh            # publish_if_absent, shared by the wrapper and the next script
│   └── ccorch-pane-died.sh      # Run by the pane's tmux pane-died hook after a SIGKILL
├── docs/                        # Getting-started guides, sdd/
├── CHANGELOG.md                 # Release notes
├── LICENSE                      # MIT
└── README.md                    # Installation & usage
```

---

## Document Structure

```
docs/sdd/design/
├── index.md                     # This file
├── components/
│   ├── skill.md                # SKILL.md design
│   ├── wrapper-script.md       # Wrapper script design
│   └── result-aggregator.md    # Result aggregation design
└── decisions/
    ├── DEC-001.md              # tmux wait-for signaling
    ├── DEC-002.md              # Environment variable depth propagation
    ├── DEC-003.md              # /tmp/ result storage
    ├── DEC-004.md              # v2 hybrid; three pane conditions
    ├── DEC-005.md              # pane orchestration only
    └── DEC-006.md              # auto mode and the start gate
```
