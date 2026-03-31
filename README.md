# ccorch

> **Status: Experimental** — This plugin is in early development. Each orchestration session spawns multiple Claude Code instances, which can consume significant tokens. Use with caution and monitor your usage.

tmux-based orchestration plugin for Claude Code. Delegates complex tasks across multiple tmux panes with a 3-level hierarchy.

## Prerequisites

- [tmux](https://github.com/tmux/tmux) 1.8+ (required for `wait-for` command)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI

## Installation

```bash
# Add the marketplace
/plugin marketplace add LevNas/claudecode-plugins

# Install the plugin
/plugin install ccorch@levnas-plugins
```

## Usage

```
/ccor <task description>
```

Example:

```
/ccor Refactor the authentication module — extract middleware, add unit tests, update API docs
```

## How It Works

```
Your Session ──► Main Brain (DEPTH=1)
                  ├── Child A (DEPTH=2)
                  │     └── Grandchild A-1 (DEPTH=3)
                  └── Child B (DEPTH=2)
                        └── Grandchild B-1 (DEPTH=3)
```

1. `/ccor` creates a **Main Brain** pane that analyzes and decomposes your task
2. Main Brain delegates subtasks to **Child** panes for parallel execution
3. Children can further delegate to **Grandchild** panes (max depth)
4. Results flow back up via `tmux wait-for` signals and file exchange
5. Your session continues working in parallel — you're notified on completion

### Safety

- **Tool restrictions**: Each depth level has progressively stricter `--allowedTools`
- **Depth limit**: Grandchildren (DEPTH=3) cannot create new panes (`Agent` tool disabled)
- **Bash restrictions**: Destructive commands (`git push --force`, `rm -rf`) are pattern-blocked
- **Timeout**: Panes auto-terminate after configurable timeout (default: 600s)

## Configuration

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `CCORCH_TIMEOUT` | `600` | Timeout in seconds per pane |
| `CCORCH_MAX_PANES` | `8` | Maximum total panes per session |
| `CCORCH_MAX_CHILDREN_D1` | `3` | Max concurrent children for Main Brain |
| `CCORCH_MAX_CHILDREN_D2` | `2` | Max concurrent grandchildren per Child |

## Optional Integrations

| Plugin | Integration |
|--------|-------------|
| [ccmemo](https://github.com/LevNas/ccmemo) | Persist discoveries via `/record-knowledge`, track plans via `/plan-task` |
| [ccresmon](https://github.com/LevNas/ccresmon) | Resource monitoring for spawned panes |

## License

MIT
