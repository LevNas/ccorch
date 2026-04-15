#!/bin/bash
# stop_signal.sh — Signal parent on ccorch worker completion
#
# Only acts inside ccorch orchestration (CCORCH_PARENT_CHANNEL is set).
# No-op for normal Claude Code sessions.

[ -n "${CCORCH_PARENT_CHANNEL:-}" ] || exit 0

tmux wait-for -S "$CCORCH_PARENT_CHANNEL" 2>/dev/null || true
