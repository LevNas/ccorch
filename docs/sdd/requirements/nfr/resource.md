# Resource Constraints

## NFR-RES-001: Concurrent Pane Limit

The total number of panes created per orchestration session shall default to a maximum of 8 (approximately: 1 Main Brain + 3 Children + 4 Grandchildren). Configurable via `CCORCH_MAX_PANES` environment variable.

## NFR-RES-002: Host Resource Constraint Alignment

The system shall respect host resource constraints (parallel agents max 2-3 as per CLAUDE.md). If ccresmon is installed, the system shall follow its resource controls.
