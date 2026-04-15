# Component: Result Aggregator

## Purpose

The Main Brain aggregates results from all child panes into a final `result.md` that is read by the user's session. This is not a separate script — it's a behavior defined in the Main Brain's system prompt.

## Aggregation Flow

```
1. Main Brain creates N children
2. Each child writes to /tmp/ccorch/<id>/child-<n>.md
3. Main Brain waits for all children (tmux wait-for per child)
4. Main Brain reads all child result files
5. Main Brain writes aggregated /tmp/ccorch/<id>/result.md
6. Main Brain signals parent: tmux wait-for -S CCORCH_DONE_<id>
```

## Result File Format

### Child Result (`child-<n>.md`)

```markdown
---
status: success | error | timeout
depth: 2
task: "Brief task description"
started: 2026-03-31T16:30:00+09:00
completed: 2026-03-31T16:35:00+09:00
---

# Results

## Execution Summary
What was done and the outcome.

## Changed Files
- path/to/file1.ts — added authentication middleware
- path/to/file2.ts — updated imports

## Discoveries
Any unexpected findings or important observations.
```

### Aggregated Result (`result.md`)

```markdown
---
status: success | partial | error
total_children: 3
succeeded: 2
failed: 1
session_id: 1711871234
started: 2026-03-31T16:30:00+09:00
completed: 2026-03-31T16:40:00+09:00
---

# Orchestration Results

## Task
Original task description from user.

## Summary
High-level summary of what was accomplished.

## Child Results

### Child 1: [task summary] — SUCCESS
[condensed results]

### Child 2: [task summary] — SUCCESS
[condensed results]

### Child 3: [task summary] — ERROR
[error details]

## All Changed Files
- path/to/file1.ts
- path/to/file2.ts
- path/to/file3.ts

## Discoveries
Aggregated discoveries from all children.
```

## Status Determination

| Condition | Aggregated Status |
|-----------|------------------|
| All children succeeded | `success` |
| Some succeeded, some failed | `partial` |
| All failed | `error` |

## System Prompt Instructions

The Main Brain's system prompt includes aggregation instructions:

```
## Result Aggregation
After all children complete:
1. Read each result file in $CCORCH_WORK_DIR
2. Check status of each (success/error/timeout)
3. Write aggregated result.md with:
   - Overall status (success/partial/error)
   - Summary of all child outcomes
   - Combined list of changed files
   - Combined discoveries
4. Signal completion: tmux wait-for -S $CCORCH_PARENT_CHANNEL
```

## Error Handling

- If a child times out, include its timeout status in the aggregation
- If a child errors, include the error details
- The Main Brain should still produce a result.md even if all children fail
- Partial results are valuable — never discard successful child results due to other failures
