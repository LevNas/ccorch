# ccorch Ledger

The ledger is the thread-name → agentId registry for subagent orchestration.
Agents do not know their own agentId, and `SendMessage` (resume) needs it —
a missed record means a lost resume handle. Hooks maintain the ledger
automatically; this file documents the format and its limits.

## Location

`<project>/.claude/ccorch/ledger.jsonl` — one JSON object per line.

Operational state, not knowledge: add `.claude/ccorch/` to `.gitignore`.
There is no automatic rotation yet; truncate or archive the file when a
project accumulates history you no longer need.

## Records

Written by `hooks/ledger_record.sh` (PostToolUse on Agent) and
`hooks/ledger_stop.sh` (SubagentStop).

### `launch`

```json
{"schema":"ccorch.ledger/1","ts":"2026-08-10T12:00:00Z","event":"launch",
 "session_id":"...","agent_id":"a1b2c3...","agent_type":"ccorch:worktree-worker",
 "model":null,"background":true,"thread":"implement parser task"}
```

- `agent_id` — extracted from the spawn response text; `null` when the
  pattern is absent (the record still counts for the parallel cap).
- `model` — only an explicit per-call override; `null` means the agent
  definition's frontmatter (or inheritance) decided.
- `thread` — the short `description` parameter only. Prompt bodies are
  deliberately not persisted (secrets baseline for on-disk state).

### `stop`

```json
{"schema":"ccorch.ledger/1","ts":"2026-08-10T12:05:00Z","event":"stop",
 "session_id":"...","agent_id":"a1b2c3...","agent_type":"ccorch:worktree-worker",
 "stop_reason":"end_turn"}
```

## Derived state and its accuracy

`running = launches - stops` per `session_id` (used by the gate's parallel
cap). This is best-effort:

- A resumed agent stops again → extra `stop` records → undercount, which
  only **relaxes** the cap (fail-open direction).
- Synchronous spawns record launch and stop around the same time → net zero.
- Cross-check live state with `ListAgents` when it matters.

## Resume

To resume a thread, find its latest `launch` by `thread`/`ts` and use the
`agent_id` with `SendMessage`. Ledger entries survive context compaction —
that is their point: the registry outlives what the session window retains.
