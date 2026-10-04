#!/bin/bash
# test_wrapper.sh — dry-run tests for the start gate and claude arguments of
# scripts/ccorch-wrapper.sh. Plain bash; no tmux or claude needed (both are faked).
#
# Usage: bash tests/test_wrapper.sh

# No `set -e`: a refusing wrapper exits 1 and the harness must keep going.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
WRAPPER="${HERE}/../scripts/ccorch-wrapper.sh"

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

# --- Fakes at the front of PATH ---

FAKE_BIN="${ROOT}/bin"
PANES_FILE="${ROOT}/live-panes"   # what the fake `tmux list-panes` prints
mkdir -p "$FAKE_BIN"

cat > "${FAKE_BIN}/tmux" <<EOF
#!/usr/bin/env bash
case "\$1" in
  list-panes) cat "$PANES_FILE" ;;
  display-message) echo "%99" ;;
  *) ;;
esac
exit 0
EOF
cat > "${FAKE_BIN}/claude" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${ROOT}/claude-was-run"
exit 0
EOF
chmod +x "${FAKE_BIN}/tmux" "${FAKE_BIN}/claude"
export PATH="${FAKE_BIN}:${PATH}"

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

# --- Helpers ---

CASE_N=0
WORK_DIR=""
OUT=""
RC=0

new_case() {
  CASE_N=$((CASE_N + 1))
  WORK_DIR="${ROOT}/case${CASE_N}"
  mkdir -p "$WORK_DIR"
  : > "$PANES_FILE"
}

# record_pane <id> <pane_id> [<parent_id>] — a ccorch pane recorded in WORK_DIR
record_pane() {
  printf '%s' "$2" > "${WORK_DIR}/$1.pane"   # no trailing newline, on purpose
  if [ -n "${3:-}" ]; then printf '%s' "$3" > "${WORK_DIR}/$1.parent"; fi
}

live() { printf '%s\n' "$@" >> "$PANES_FILE"; }

# run_wrapper <depth> [VAR=value ...] — dry run; sets OUT and RC
run_wrapper() {
  local depth="$1"; shift
  RC=0
  OUT=$(env -u CCORCH_PARENT_ID -u CCORCH_MAX_PANES \
            -u CCORCH_MAX_CHILDREN_D1 -u CCORCH_MAX_CHILDREN_D2 \
            CCORCH_DRY_RUN=1 CCORCH_DEPTH="$depth" CCORCH_SESSION_ID=test \
            CCORCH_PARENT_CHANNEL=test-channel CCORCH_WORK_DIR="$WORK_DIR" \
            CCORCH_PROJECT_DIR="$ROOT" "$@" \
            bash "$WRAPPER" 'test task' 2>/dev/null) || RC=$?
}

result_files() { ls "${WORK_DIR}"/depth*.md 2>/dev/null || true; }

# argv_elements — the claude argv from OUT, one element per line, unescaped
argv_elements() {
  local line
  printf '%s\n' "$OUT" | sed -n 's/^argv: //p' | while IFS= read -r line; do
    eval "printf '%s\n' $line"
  done
}

# has_element <element> — whole argv element present
has_element() { argv_elements | grep -qxF -- "$1"; }

# deny_rules — elements strictly between --disallowedTools and --append-system-prompt
deny_rules() {
  argv_elements | awk '$0=="--disallowedTools"{on=1;next} $0=="--append-system-prompt"{on=0} on'
}
has_deny() { deny_rules | grep -qxF -- "$1"; }

# mode_is_auto — "auto" is the element right after --permission-mode
mode_is_auto() {
  argv_elements | awk 'prev=="--permission-mode"{print} {prev=$0}' | grep -qxF auto
}

expect() { # expect <description> <command...>
  local desc="$1"; shift
  if "$@"; then ok "$desc"; else fail "$desc"; fi
}

refused_with() { # refused_with <reason fragment>
  [ "$RC" -ne 0 ] && printf '%s\n' "$OUT" | grep -qF "gate: refused" \
    && printf '%s\n' "$OUT" | grep -qF -- "$1" \
    && grep -qF 'status: refused' $(result_files)
}

gate_ok() { [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qxF 'gate: ok'; }

# --- Cases: claude arguments at every depth ---

for depth in 1 2 3; do
  new_case
  if [ "$depth" -eq 1 ]; then run_wrapper 1; else run_wrapper "$depth" CCORCH_PARENT_ID=parent-1; fi
  expect "depth $depth: gate ok" gate_ok
  expect "depth $depth: no --dangerously-skip-permissions" \
    bash -c '! grep -q -- "--dangerously-skip-permissions" <<< "$1"' _ "$OUT"
  expect "depth $depth: no --allowedTools" \
    bash -c '! grep -q -- "--allowedTools" <<< "$1"' _ "$OUT"
  expect "depth $depth: auto follows --permission-mode" mode_is_auto
  for rule in 'Bash(rm -rf *)' 'Bash(git push --force *)' 'Bash(git push -f *)' \
              'Bash(git reset --hard *)' 'Bash(git clean *)' 'Bash(sudo *)'; do
    expect "depth $depth: deny rule '$rule' between the flags" has_deny "$rule"
  done
done

# --- Per-depth differences ---

new_case; run_wrapper 3 CCORCH_PARENT_ID=parent-1
expect "depth 3: Agent denied" has_deny 'Agent'
expect "depth 3: Bash(tmux *) denied" has_deny 'Bash(tmux *)'
expect "depth 3: Bash(git push *) denied" has_deny 'Bash(git push *)'

new_case; run_wrapper 2 CCORCH_PARENT_ID=parent-1
expect "depth 2: Bash(git push *) denied" has_deny 'Bash(git push *)'
if has_deny 'Agent'; then fail "depth 2: Agent not denied"; else ok "depth 2: Agent not denied"; fi
if has_deny 'Bash(tmux *)'; then fail "depth 2: tmux not denied"; else ok "depth 2: tmux not denied"; fi

new_case; run_wrapper 1
if has_deny 'Bash(git push *)'; then fail "depth 1: git push not denied"; else ok "depth 1: git push not denied"; fi
if has_deny 'Agent'; then fail "depth 1: Agent not denied"; else ok "depth 1: Agent not denied"; fi
if has_deny 'Bash(tmux *)'; then fail "depth 1: tmux not denied"; else ok "depth 1: tmux not denied"; fi
expect "depth 1 without CCORCH_PARENT_ID: gate ok" gate_ok

# --- Depth gate ---

new_case; run_wrapper 4 CCORCH_PARENT_ID=parent-1
expect "depth 4: refused, result has status: refused" refused_with "CCORCH_DEPTH must be 1, 2 or 3"

new_case; run_wrapper abc
expect "depth 'abc': refused" refused_with "CCORCH_DEPTH must be 1, 2 or 3"

# --- Pane limit (children limits left high so only the pane limit can refuse) ---

new_case
record_pane depthA-000001 %11; record_pane depthA-000002 %12
live %11 %12 %99
run_wrapper 1 CCORCH_MAX_PANES=3
expect "MAX_PANES=3, 2 live recorded: ok" gate_ok

new_case
record_pane depthA-000001 %11; record_pane depthA-000002 %12; record_pane depthA-000003 %13
live %11 %12 %13 %99
run_wrapper 1 CCORCH_MAX_PANES=3
expect "MAX_PANES=3, 3 live recorded: refused (pane limit)" refused_with "pane limit"

new_case
record_pane depthA-000001 %11; record_pane depthA-000002 %12; record_pane depthA-000003 %13
live %11 %12 %99   # %13 is dead
run_wrapper 1 CCORCH_MAX_PANES=3
expect "MAX_PANES=3, 3 recorded but 1 dead: ok" gate_ok

new_case
record_pane depthA-000001 %99   # the current pane itself is not counted
live %99
run_wrapper 1 CCORCH_MAX_PANES=1
expect "current pane id excluded from the live count" gate_ok

new_case
run_wrapper 1 CCORCH_MAX_PANES=3
expect "gate writes .pane for the started pane" bash -c 'ls "$1"/depth1-*.pane >/dev/null 2>&1' _ "$WORK_DIR"

# --- Children per parent (pane limit left high) ---

new_case
record_pane depthB-000001 %11 parent-1; record_pane depthB-000002 %12 parent-1
live %11 %12 %99
run_wrapper 2 CCORCH_PARENT_ID=parent-1 CCORCH_MAX_CHILDREN_D1=2 CCORCH_MAX_PANES=20
expect "MAX_CHILDREN_D1=2, 2 live siblings at depth 2: refused (children limit)" refused_with "children limit"

new_case
record_pane depthB-000001 %11 parent-1; record_pane depthB-000002 %12 parent-2
live %11 %12 %99
run_wrapper 2 CCORCH_PARENT_ID=parent-1 CCORCH_MAX_CHILDREN_D1=2 CCORCH_MAX_PANES=20
expect "siblings under another parent are not counted: ok" gate_ok

new_case
record_pane depthB-000001 %11 parent-1; record_pane depthB-000002 %12 parent-1
live %11 %99   # %12 is dead
run_wrapper 2 CCORCH_PARENT_ID=parent-1 CCORCH_MAX_CHILDREN_D1=2 CCORCH_MAX_PANES=20
expect "dead sibling is not counted: ok" gate_ok

new_case
record_pane depthB-000001 %11 parent-1; record_pane depthB-000002 %12 parent-1
live %11 %12 %99
run_wrapper 3 CCORCH_PARENT_ID=parent-1 CCORCH_MAX_CHILDREN_D1=9 CCORCH_MAX_CHILDREN_D2=2 CCORCH_MAX_PANES=20
expect "depth 3 uses MAX_CHILDREN_D2: refused" refused_with "CCORCH_MAX_CHILDREN_D2"

new_case
run_wrapper 2
expect "depth 2 without CCORCH_PARENT_ID: refused" refused_with "CCORCH_PARENT_ID is required"

# --- System prompt ---

new_case; run_wrapper 1 CCORCH_MAX_PANES=5 CCORCH_MAX_CHILDREN_D1=2 CCORCH_MAX_CHILDREN_D2=1
PROMPT_FILE="${WORK_DIR}/dry-run.system-prompt"
for needle in 'CCORCH_MAX_PANES=5' 'CCORCH_MAX_CHILDREN_D1=2' 'CCORCH_MAX_CHILDREN_D2=1' 'CCORCH_PARENT_ID='; do
  expect "depth 1 prompt: split-pane template has ${needle}" grep -qF -- "$needle" "$PROMPT_FILE"
done

new_case; run_wrapper 2 CCORCH_PARENT_ID=parent-1 CCORCH_MAX_PANES=5 CCORCH_MAX_CHILDREN_D1=2 CCORCH_MAX_CHILDREN_D2=1
PROMPT_FILE="${WORK_DIR}/dry-run.system-prompt"
for needle in 'CCORCH_MAX_PANES=5' 'CCORCH_MAX_CHILDREN_D1=2' 'CCORCH_MAX_CHILDREN_D2=1' 'CCORCH_PARENT_ID='; do
  expect "depth 2 prompt: split-pane template has ${needle}" grep -qF -- "$needle" "$PROMPT_FILE"
done

# --- Dry run does not start claude, and writes status: dry-run ---

new_case; run_wrapper 1
expect "dry run: claude not started" test ! -e "${ROOT}/claude-was-run"
expect "dry run: result file says status: dry-run" grep -qF 'status: dry-run' $(result_files)

echo
echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
