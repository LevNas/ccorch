#!/bin/bash
# test_wrapper.sh — tests for the start gate and the claude arguments of
# scripts/ccorch-wrapper.sh. Plain bash; no tmux or claude needed (both are faked).
#
# Most cases use CCORCH_DRY_RUN=1. The cases that need a real start (records written,
# signalling on refusal, claude's exit status) run the wrapper without it, against the
# fake claude, in their own process group: the wrapper's watchdog ends with `kill 0`.
#
# Usage: bash tests/test_wrapper.sh

# No `set -e`: a refusing wrapper exits 1 and the harness must keep going. No
# pipefail either: `grep -q` closes its pipe early and would fail the pipeline.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
WRAPPER="${HERE}/../scripts/ccorch-wrapper.sh"

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

# --- Fakes at the front of PATH ---
# Everything they read or write is per case, set by new_case.

FAKE_BIN="${ROOT}/bin"
mkdir -p "$FAKE_BIN"

cat > "${FAKE_BIN}/tmux" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_TMUX_LOG"
case "$1" in
  list-panes)
    [ -e "$FAKE_LIST_FAIL" ] && exit 1
    cat "$FAKE_PANES_FILE"
    ;;
  display-message) echo "%99" ;;
esac
exit 0
EOF
cat > "${FAKE_BIN}/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_CLAUDE_ARGV"
exit "${FAKE_CLAUDE_RC:-0}"
EOF
chmod +x "${FAKE_BIN}/tmux" "${FAKE_BIN}/claude"
export PATH="${FAKE_BIN}:${PATH}"

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

expect() { # expect <description> <command...>
  local desc="$1"; shift
  if "$@"; then ok "$desc"; else fail "$desc"; fi
}
expect_not() { # expect_not <description> <command...>
  local desc="$1"; shift
  if "$@"; then fail "$desc"; else ok "$desc"; fi
}

# Run a command in its own process group, and wait for it (keeps its exit status).
if command -v setsid >/dev/null 2>&1; then
  run_pg() { setsid -w "$@"; }
else
  run_pg() { ( set -m; "$@" & wait $! ); }
fi

# --- Per-case state ---

CASE_N=0
CASE_DIR=""
WORK_DIR=""
OUT=""
ERR=""
RC=0

new_case() {
  CASE_N=$((CASE_N + 1))
  CASE_DIR="${ROOT}/case${CASE_N}"
  WORK_DIR="${CASE_DIR}/work"
  mkdir -p "$WORK_DIR"
  export FAKE_PANES_FILE="${CASE_DIR}/live-panes"
  export FAKE_TMUX_LOG="${CASE_DIR}/tmux.log"
  export FAKE_LIST_FAIL="${CASE_DIR}/list-panes-fails"
  export FAKE_CLAUDE_ARGV="${CASE_DIR}/claude-argv"
  export FAKE_CLAUDE_RC=0
  : > "$FAKE_PANES_FILE"
  : > "$FAKE_TMUX_LOG"
}

# Pane ids: the fake tmux reports the current pane as %99; fixtures use other ids.

live() { printf '%s\n' "$@" >> "$FAKE_PANES_FILE"; }

# record_pane <id> <pane_id> [<parent_id>] — a pane recorded in WORK_DIR, listed as alive.
# No .depth file: it only takes part in the pane and sibling counts.
record_pane() {
  printf '%s' "$2" > "${WORK_DIR}/$1.pane"   # no trailing newline, on purpose
  if [ -n "${3:-}" ]; then printf '%s' "$3" > "${WORK_DIR}/$1.parent"; fi
  live "$2"
}

# seed_pane <id> <pane_id> <depth> — a full record, as the gate writes it, listed as alive.
seed_pane() {
  printf '%s' "$2" > "${WORK_DIR}/$1.pane"
  printf '%s' "$3" > "${WORK_DIR}/$1.depth"
  live "$2"
}

# seed_parent <depth of the pane under test> — the live parent that depth needs.
seed_parent() {
  seed_pane parent-1 %21 $(($1 - 1))
}

# run_wrapper <dry:1|0> <depth> [VAR=value ...] — sets OUT, ERR and RC.
# Output goes to files, not to $(...): the wrapper's background sleeps would hold a pipe.
run_wrapper() {
  local dry="$1" depth="$2"; shift 2
  local dry_env=()
  if [ "$dry" = 1 ]; then dry_env=(CCORCH_DRY_RUN=1); fi
  RC=0
  run_pg env -u CCORCH_PARENT_ID -u CCORCH_MAX_PANES \
      -u CCORCH_MAX_CHILDREN_D1 -u CCORCH_MAX_CHILDREN_D2 -u CCORCH_DRY_RUN \
      "${dry_env[@]}" CCORCH_DEPTH="$depth" CCORCH_SESSION_ID=test \
      CCORCH_PARENT_CHANNEL=test-channel CCORCH_WORK_DIR="$WORK_DIR" \
      CCORCH_PROJECT_DIR="$ROOT" CCORCH_TIMEOUT=30 "$@" \
      bash "$WRAPPER" 'test task' > "${CASE_DIR}/out" 2> "${CASE_DIR}/err" < /dev/null || RC=$?
  OUT=$(cat "${CASE_DIR}/out")
  ERR=$(cat "${CASE_DIR}/err")
}
run_dry()  { run_wrapper 1 "$@"; }
run_real() { run_wrapper 0 "$@"; }

# --- Assertion helpers ---

# result_path — the one result file of the wrapper under test; fails unless exactly one.
result_path() {
  local files=("${WORK_DIR}"/depth*.md)
  [ "${#files[@]}" -eq 1 ] && [ -f "${files[0]}" ] || return 1
  printf '%s' "${files[0]}"
}
# result_has <fragment> — the one result file contains the fragment.
result_has() {
  local path
  path=$(result_path) || return 1
  grep -qF -- "$1" "$path"
}
# child_id — the wrapper's CHILD_ID, from the name of its result file.
child_id() {
  local path
  path=$(result_path) || return 1
  basename "$path" .md
}

gate_ok() { [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qxF 'gate: ok'; }

# refused_with <reason fragment> — exit 1, message on stderr, status: refused with the reason.
refused_with() {
  [ "$RC" -eq 1 ] && printf '%s\n' "$ERR" | grep -qF -- "$1" \
    && result_has 'status: refused' && result_has "$1"
}

# argv_elements — the claude argv from a dry run, one element per line, unescaped
argv_elements() {
  local line
  printf '%s\n' "$OUT" | sed -n 's/^argv: //p' | while IFS= read -r line; do
    eval "printf '%s\n' $line"
  done
}
# deny_rules — elements strictly between --disallowedTools and --append-system-prompt
deny_rules() {
  argv_elements | awk '$0=="--disallowedTools"{on=1;next} $0=="--append-system-prompt"{on=0} on'
}
has_deny() { deny_rules | grep -qxF -- "$1"; }
# mode_is_auto — "auto" is the element right after --permission-mode
mode_is_auto() {
  argv_elements | awk 'prev=="--permission-mode"{print} {prev=$0}' | grep -qxF auto
}
argv_has() { printf '%s\n' "$OUT" | grep -qF -- "$1"; }

# file_is <path> <content> — a record holds exactly this content
file_is() { [ -f "$1" ] && [ "$(cat "$1")" = "$2" ]; }
no_files() { # no_files <glob...> — none of the globs matches an existing file
  local f
  for f in "$@"; do [ -e "$f" ] && return 1; done
  return 0
}
tmux_logged() { grep -qF -- "$1" "$FAKE_TMUX_LOG"; }

ALL_RULES=('Bash(rm -rf *)' 'Bash(rm -fr *)' 'Bash(rm -r -f *)' 'Bash(rm -f -r *)'
           'Bash(git push --force *)' 'Bash(git push *--force*)' 'Bash(git push -f *)'
           'Bash(git push * +*)' 'Bash(git reset --hard *)' 'Bash(git clean *)' 'Bash(sudo *)')

# --- Claude arguments at every depth ---

for depth in 1 2 3; do
  new_case
  [ "$depth" -gt 1 ] && seed_parent "$depth"
  if [ "$depth" -eq 1 ]; then run_dry 1; else run_dry "$depth" CCORCH_PARENT_ID=parent-1; fi
  expect "depth $depth: gate ok" gate_ok
  expect_not "depth $depth: no --dangerously-skip-permissions" argv_has '--dangerously-skip-permissions'
  expect_not "depth $depth: no --allowedTools" argv_has '--allowedTools'
  expect "depth $depth: auto follows --permission-mode" mode_is_auto
  for rule in "${ALL_RULES[@]}"; do
    expect "depth $depth: deny rule '$rule' between the flags" has_deny "$rule"
  done
done

# --- Per-depth differences ---

new_case; seed_parent 3; run_dry 3 CCORCH_PARENT_ID=parent-1
expect "depth 3: Agent denied" has_deny 'Agent'
expect "depth 3: Bash(tmux *) denied" has_deny 'Bash(tmux *)'
expect "depth 3: Bash(git push *) denied" has_deny 'Bash(git push *)'

new_case; seed_parent 2; run_dry 2 CCORCH_PARENT_ID=parent-1
expect "depth 2: Bash(git push *) denied" has_deny 'Bash(git push *)'
expect_not "depth 2: Agent not denied" has_deny 'Agent'
expect_not "depth 2: tmux not denied" has_deny 'Bash(tmux *)'

new_case; run_dry 1
expect_not "depth 1: git push not denied" has_deny 'Bash(git push *)'
expect_not "depth 1: Agent not denied" has_deny 'Agent'
expect_not "depth 1: tmux not denied" has_deny 'Bash(tmux *)'
expect "depth 1 without CCORCH_PARENT_ID: gate ok" gate_ok

# --- Depth range ---

new_case; run_dry 4 CCORCH_PARENT_ID=parent-1
expect "depth 4: refused, result has status: refused" refused_with "CCORCH_DEPTH must be 1, 2 or 3"

new_case; run_dry abc
expect "depth 'abc': refused" refused_with "CCORCH_DEPTH must be 1, 2 or 3"

# --- Depth follows the parent's record, not the environment ---

new_case; seed_parent 2; run_dry 3 CCORCH_PARENT_ID=parent-1
expect "claimed depth 3 under a depth-1 parent: refused, both numbers named" \
  refused_with "CCORCH_DEPTH=3 disagrees with the parent's recorded depth 1 (expected 2)"

new_case; seed_pane parent-1 %21 2; run_dry 2 CCORCH_PARENT_ID=parent-1
expect "claimed depth 2 under a depth-2 parent: refused" \
  refused_with "CCORCH_DEPTH=2 disagrees with the parent's recorded depth 2 (expected 3)"

new_case; seed_parent 2; run_dry 1 CCORCH_PARENT_ID=parent-1
expect "claimed depth 1 with a parent: refused" refused_with "CCORCH_DEPTH=1 disagrees"

new_case; run_dry 2 CCORCH_PARENT_ID=ghost
expect "missing parent record: refused" refused_with "no record of parent ghost"

new_case; seed_parent 2; : > "$FAKE_PANES_FILE"; live %99
run_dry 2 CCORCH_PARENT_ID=parent-1
expect "dead parent pane: refused" refused_with "parent parent-1 is not alive"

new_case; seed_pane parent-1 %21 0; run_dry 2 CCORCH_PARENT_ID=parent-1
expect "parent with an invalid recorded depth: refused" refused_with "invalid recorded depth"

new_case; run_dry 2 'CCORCH_PARENT_ID=../x'
expect "parent id with path characters: refused" refused_with "CCORCH_PARENT_ID contains characters"

new_case; run_dry 2
expect "depth 2 without CCORCH_PARENT_ID: refused" refused_with "CCORCH_PARENT_ID is required"

new_case; seed_pane main-1 %21 1; run_dry 1
expect "second depth 1 in the same WORK_DIR: refused" refused_with "a Main Brain is already running"

new_case; seed_pane main-1 %21 1; : > "$FAKE_PANES_FILE"; live %99
run_dry 1
expect "depth 1 after a dead Main Brain: ok" gate_ok

# --- Limits must be positive integers ---

for var in CCORCH_MAX_PANES CCORCH_MAX_CHILDREN_D1 CCORCH_MAX_CHILDREN_D2; do
  new_case; run_dry 1 "${var}=abc"
  expect "${var}=abc: refused, names the variable" refused_with "${var} must be a positive integer"
  new_case; run_dry 1 "${var}=0"
  expect "${var}=0: refused" refused_with "${var} must be a positive integer"
  new_case; run_dry 1 "${var}="
  expect "${var} empty: treated as unset, the default applies" gate_ok
done

# --- tmux failures fail closed ---

new_case; touch "$FAKE_LIST_FAIL"
record_pane depthA-1 %11
run_dry 1
expect "list-panes fails: refused, not counted as dead" refused_with "tmux list-panes failed"

# --- Pane limit (children limits are not involved at depth 1) ---

new_case; record_pane depthA-1 %11; record_pane depthA-2 %12; live %99
run_dry 1 CCORCH_MAX_PANES=3
expect "MAX_PANES=3, 2 live recorded: ok" gate_ok

new_case; record_pane depthA-1 %11; record_pane depthA-2 %12; record_pane depthA-3 %13
run_dry 1 CCORCH_MAX_PANES=3
expect "MAX_PANES=3, 3 live recorded: refused (pane limit)" refused_with "pane limit reached"

new_case; record_pane depthA-1 %11; record_pane depthA-2 %12; record_pane depthA-3 %13
: > "$FAKE_PANES_FILE"; live %11 %12 %99   # %13 is dead
run_dry 1 CCORCH_MAX_PANES=3
expect "MAX_PANES=3, 3 recorded but 1 dead: ok" gate_ok

new_case; record_pane depthA-1 %99; run_dry 1 CCORCH_MAX_PANES=1
expect "the current pane id is excluded from the live count" gate_ok

# --- Children per parent; the limit follows the pane's own depth ---

new_case; seed_parent 2
record_pane depthB-1 %11 parent-1; record_pane depthB-2 %12 parent-1
run_dry 2 CCORCH_PARENT_ID=parent-1 CCORCH_MAX_CHILDREN_D1=3 CCORCH_MAX_CHILDREN_D2=1 CCORCH_MAX_PANES=20
expect "depth 2, D1=3 D2=1, 2 live siblings: ok (keyed on D1)" gate_ok

new_case; seed_parent 2
record_pane depthB-1 %11 parent-1; record_pane depthB-2 %12 parent-1
run_dry 2 CCORCH_PARENT_ID=parent-1 CCORCH_MAX_CHILDREN_D1=2 CCORCH_MAX_CHILDREN_D2=9 CCORCH_MAX_PANES=20
expect "depth 2, D1=2 D2=9, 2 live siblings: refused, names D1" refused_with "CCORCH_MAX_CHILDREN_D1=2"

new_case; seed_parent 3
record_pane depthB-1 %11 parent-1; record_pane depthB-2 %12 parent-1
run_dry 3 CCORCH_PARENT_ID=parent-1 CCORCH_MAX_CHILDREN_D1=1 CCORCH_MAX_CHILDREN_D2=3 CCORCH_MAX_PANES=20
expect "depth 3, D1=1 D2=3, 2 live siblings: ok (keyed on D2)" gate_ok

new_case; seed_parent 3
record_pane depthB-1 %11 parent-1; record_pane depthB-2 %12 parent-1
run_dry 3 CCORCH_PARENT_ID=parent-1 CCORCH_MAX_CHILDREN_D1=9 CCORCH_MAX_CHILDREN_D2=2 CCORCH_MAX_PANES=20
expect "depth 3, D1=9 D2=2, 2 live siblings: refused, names D2" refused_with "CCORCH_MAX_CHILDREN_D2=2"

new_case; seed_parent 2
record_pane depthB-1 %11 parent-1; record_pane depthB-2 %12 parent-2
run_dry 2 CCORCH_PARENT_ID=parent-1 CCORCH_MAX_CHILDREN_D1=2 CCORCH_MAX_PANES=20
expect "siblings under another parent are not counted: ok" gate_ok

new_case; seed_parent 2
record_pane depthB-1 %11 parent-1; record_pane depthB-2 %12 parent-1
: > "$FAKE_PANES_FILE"; live %21 %11 %99   # %12 is dead
run_dry 2 CCORCH_PARENT_ID=parent-1 CCORCH_MAX_CHILDREN_D1=2 CCORCH_MAX_PANES=20
expect "a dead sibling is not counted: ok" gate_ok

# --- Records: written by a real start only ---

new_case; seed_parent 2
run_real 2 CCORCH_PARENT_ID=parent-1
ID=$(child_id)
expect "real start: wrapper exits 0" test "$RC" -eq 0
expect "real start: .pane holds the current pane id" file_is "${WORK_DIR}/${ID}.pane" '%99'
expect "real start: .parent holds the parent id" file_is "${WORK_DIR}/${ID}.parent" 'parent-1'
expect "real start: .depth holds the depth" file_is "${WORK_DIR}/${ID}.depth" '2'
expect "real start: claude was started" test -f "$FAKE_CLAUDE_ARGV"
expect "real start: lock released" test ! -e "${WORK_DIR}/.lock.d"

new_case; run_dry 1
expect "dry run: no .pane, .parent or .depth written" \
  no_files "${WORK_DIR}"/depth*.pane "${WORK_DIR}"/depth*.parent "${WORK_DIR}"/depth*.depth
expect "dry run: status.md not written" test ! -e "${WORK_DIR}/status.md"
expect "dry run: claude not started" test ! -e "$FAKE_CLAUDE_ARGV"
expect "dry run: result file says status: dry-run" result_has 'status: dry-run'
expect "dry run: parent channel not signalled" bash -c '! grep -qF "wait-for" "$1"' _ "$FAKE_TMUX_LOG"
expect "dry run: lock released" test ! -e "${WORK_DIR}/.lock.d"

# --- Refusal in a real start signals the parent and never reaches claude ---

new_case; run_real 4 CCORCH_PARENT_ID=parent-1
expect "real start, depth 4: refused with status: refused" refused_with "CCORCH_DEPTH must be 1, 2 or 3"
expect "real start, depth 4: parent channel signalled" tmux_logged 'wait-for -S test-channel'
expect "real start, depth 4: claude not reached" test ! -e "$FAKE_CLAUDE_ARGV"

# --- claude's exit status is not discarded ---

new_case; export FAKE_CLAUDE_RC=3; run_real 1
expect "claude exits 3, no result file: status: error" result_has 'status: error'
expect "claude exits 3, no result file: exit code recorded" result_has 'exit_code: 3'
expect_not "claude exits 3, no result file: not success" result_has 'status: success'

new_case; run_real 1
expect "claude exits 0, no result file: status: incomplete" result_has 'status: incomplete'
expect_not "claude exits 0, no result file: not success" result_has 'status: success'

# --- Lock ---

new_case; mkdir "${WORK_DIR}/.lock.d"
touch -t "$(date -d '2 minutes ago' +%Y%m%d%H%M 2>/dev/null || date -v-2M +%Y%m%d%H%M)" "${WORK_DIR}/.lock.d"
run_dry 1
expect "stale lock directory: recovered, gate ok" gate_ok
expect "stale lock directory: released afterwards" test ! -e "${WORK_DIR}/.lock.d"

new_case; mkdir "${WORK_DIR}/.lock.d"
run_dry 1
expect "fresh lock held by someone else: refused after the timeout" refused_with "lock timeout"
expect "fresh lock held by someone else: left in place" test -d "${WORK_DIR}/.lock.d"

# --- System prompt ---

new_case; run_dry 1 CCORCH_MAX_PANES=5 CCORCH_MAX_CHILDREN_D1=2 CCORCH_MAX_CHILDREN_D2=1
ID=$(child_id)
PROMPT_FILE="${WORK_DIR}/${ID}.dry-run.system-prompt"
for needle in 'CCORCH_MAX_PANES=5' 'CCORCH_MAX_CHILDREN_D1=2' 'CCORCH_MAX_CHILDREN_D2=1' "CCORCH_PARENT_ID=${ID} "; do
  expect "depth 1 prompt: split-pane template has ${needle}" grep -qF -- "$needle" "$PROMPT_FILE"
done

new_case; seed_parent 2
run_dry 2 CCORCH_PARENT_ID=parent-1 CCORCH_MAX_PANES=5 CCORCH_MAX_CHILDREN_D1=2 CCORCH_MAX_CHILDREN_D2=1
ID=$(child_id)
PROMPT_FILE="${WORK_DIR}/${ID}.dry-run.system-prompt"
for needle in 'CCORCH_MAX_PANES=5' 'CCORCH_MAX_CHILDREN_D1=2' 'CCORCH_MAX_CHILDREN_D2=1' "CCORCH_PARENT_ID=${ID} "; do
  expect "depth 2 prompt: split-pane template has ${needle}" grep -qF -- "$needle" "$PROMPT_FILE"
done

echo
echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
