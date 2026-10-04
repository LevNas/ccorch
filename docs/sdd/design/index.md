# Design

> This document assumes implementation by AI agents (Claude Code, etc.).
> Sections clearly distinguish "explicitly specified" from "unknown/to-be-confirmed" information.

## Explicitly Specified Information

- [x] Technology: tmux (wait-for signaling), Claude Code CLI (`-p`, `--allowedTools`, `--append-system-prompt`)
- [x] Architecture: 3-level tmux pane hierarchy with environment variable depth propagation
- [x] Communication: `tmux wait-for` signals + file-based data exchange (`/tmp/ccorch/`)
- [x] Safety: system prompt guard rails per depth, plus `--allowedTools` / `--disallowedTools` flags. The wrapper also passes `--dangerously-skip-permissions`; whether the flags restrict anything under that bypass is not verified (see Security Considerations)
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
  ├── Aggregate results → /tmp/ccorch/<id>/result.md
  └── tmux wait-for -S CCORCH_DONE_<id>
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

## Security Considerations

### Depth-Based Tool Flags

What the wrapper passes (`scripts/ccorch-wrapper.sh`), and what `claude --help` says about each flag:

| Flag | DEPTH 1, 2 | DEPTH 3 | `claude --help` |
|------|-----------|---------|-----------------|
| `--dangerously-skip-permissions` | yes | yes | "Bypass all permission checks" |
| `--allowedTools` | `Read Edit Write Bash(git:status,git:diff,git:add,git:commit,tmux:*) Grep Glob Agent` | same without `tmux:*` and `Agent` | list of tool names "to allow" |
| `--disallowedTools` | not passed | `"Agent"` | list of tool names "to deny" |
| `--append-system-prompt` | yes | yes | appends a system prompt |

The help text does not say whether `--allowedTools` or `--disallowedTools` restrict anything while permissions are bypassed: **not verified**. The allowlists at DEPTH 1 and 2 are identical. The Bash patterns are not a verified block on destructive commands; the only stated ban on them is the system prompt. The wrapper writes the Bash patterns with commas inside the parentheses and a colon syntax, while the help text example is `"Bash(git *) Edit"`: how the patterns are parsed is also not verified. `--disallowedTools "Agent"` denies the subagent tool; panes are created through `tmux split-pane` via Bash, so it does not address pane creation. The blocks below show the intended flags per depth.

Intended flags per depth (DEPTH 1 and 2 are identical; only DEPTH 3 differs; see the table above for what is verified):

```bash
# DEPTH=1 (Main Brain) — intended flags; the table above says what is verified
claude --dangerously-skip-permissions \
  --allowedTools "Read Edit Write Bash(git:status,git:diff,git:add,git:commit,tmux:*) Grep Glob Agent" \
  --append-system-prompt "You are CCORCH Main Brain (DEPTH=1)..." \
  -p "$TASK"

# DEPTH=2 (Child)
claude --dangerously-skip-permissions \
  --allowedTools "Read Edit Write Bash(git:status,git:diff,git:add,git:commit,tmux:*) Grep Glob Agent" \
  --append-system-prompt "You are CCORCH Child (DEPTH=2)..." \
  -p "$TASK"

# DEPTH=3 (Grandchild)
claude --dangerously-skip-permissions \
  --allowedTools "Read Edit Write Bash(git:status,git:diff,git:add,git:commit) Grep Glob" \
  --disallowedTools "Agent" \
  --append-system-prompt "You are CCORCH Grandchild (DEPTH=3). Do NOT create new panes..." \
  -p "$TASK"
```

### Guard Rail System Prompts

Injected via `--append-system-prompt` at each depth:

| Depth | Key Rules |
|-------|-----------|
| 1 | Can delegate to children. No destructive git ops. Aggregate results before signaling parent. |
| 2 | Can delegate to grandchildren. No destructive git ops. Write results to CCORCH_WORK_DIR. |
| 3 | Cannot create panes. Execute assigned task only. Write results to CCORCH_WORK_DIR. |

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
│   └── plugin.json              # Plugin metadata (v0.1.0)
├── skills/
│   └── ccor/
│       └── SKILL.md             # Skill definition
├── scripts/
│   └── ccorch-wrapper.sh        # Child pane wrapper script
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
    └── DEC-005.md              # pane orchestration only
```
