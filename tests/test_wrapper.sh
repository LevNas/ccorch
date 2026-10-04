#!/bin/bash
# test_wrapper.sh — tests for the start gate and the claude arguments of
# scripts/ccorch-wrapper.sh. Plain bash; no tmux or claude needed (both are faked).
#
# Most cases use CCORCH_DRY_RUN=1. The cases that need a real start (records written,
# the lock, signalling on refusal, claude's exit status) run the wrapper without it,
# against the fake claude, in their own process group: the wrapper's watchdog ends with
# `kill 0`.
#
# Usage: bash tests/test_wrapper.sh

# No `set -e`: a refusing wrapper exits 1 and the harness must keep going. No
# pipefail either: `grep -q` closes its pipe early and would fail the pipeline.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
WRAPPER="${HERE}/../scripts/ccorch-wrapper.sh"

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "${ROOT}/tmp"

# --- Fakes at the front of PATH ---
# Everything they read or write is per case, set by new_case.

FAKE_BIN="${ROOT}/bin"
mkdir -p "$FAKE_BIN"

# display-message prints the -t value when given, else $FAKE_PANE_ID (default %99; may be
# set empty). list-panes can fail
# (FAKE_LIST_FAIL), be slow (FAKE_LIST_DELAY, to force races), or signal the lock owner
# with TERM first (FAKE_LIST_KILL, to end the wrapper while it holds the lock).
# FAKE_TMUX_FAIL_ON makes every command that starts with it fail (after logging it).
cat > "${FAKE_BIN}/tmux" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_TMUX_LOG"
if [ -n "${FAKE_TMUX_FAIL_ON:-}" ] && [[ "$*" == "$FAKE_TMUX_FAIL_ON"* ]]; then exit 1; fi
case "$1" in
  list-panes)
    [ -e "$FAKE_LIST_FAIL" ] && exit 1
    if [ -n "${FAKE_LIST_KILL:-}" ]; then
      owner=$(cat "$FAKE_WORK_DIR/.lock.d/owner" 2>/dev/null)
      [ -n "$owner" ] && kill -TERM "$owner"
      sleep 1
    fi
    sleep "${FAKE_LIST_DELAY:-0}"
    cat "$FAKE_PANES_FILE"
    ;;
  display-message)
    # With -t <pane> it reports that pane, as tmux does; without, $FAKE_PANE_ID.
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "-t" ]; then echo "$2"; exit 0; fi
      shift
    done
    echo "${FAKE_PANE_ID-%99}" ;;
esac
exit 0
EOF
# claude records its argv and the Stop hook's environment, and writes its result file
# with $FAKE_CLAUDE_WRITE when that is set (a pane that finished its task).
cat > "${FAKE_BIN}/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_CLAUDE_ARGV"
printf 'CCORCH_COPY_RESULT=%s\nCCORCH_RESULT_FILE=%s\n' \
  "${CCORCH_COPY_RESULT-unset}" "${CCORCH_RESULT_FILE-unset}" > "$FAKE_CLAUDE_ENV"
if [ -n "${FAKE_CLAUDE_WRITE:-}" ]; then
  printf '%s\n' "$FAKE_CLAUDE_WRITE" > "$CCORCH_RESULT_FILE"
elif [ -n "${FAKE_CLAUDE_EMPTY:-}" ]; then
  : > "$CCORCH_RESULT_FILE"
fi
# FAKE_CLAUDE_LATE_WRITE: after FAKE_CLAUDE_LATE_DELAY seconds, write the result (a pane that
# finishes while the watchdog waits out the grace on an empty file).
if [ -n "${FAKE_CLAUDE_LATE_WRITE:-}" ]; then
  sleep "${FAKE_CLAUDE_LATE_DELAY:-1}"
  printf '%s\n' "$FAKE_CLAUDE_LATE_WRITE" > "$CCORCH_RESULT_FILE"
fi
# FAKE_CLAUDE_SLEEP keeps the pane running; ".slept" shows it was not killed meanwhile.
if [ -n "${FAKE_CLAUDE_SLEEP:-}" ]; then
  sleep "$FAKE_CLAUDE_SLEEP"
  : > "${FAKE_CLAUDE_ARGV}.slept"
fi
exit "${FAKE_CLAUDE_RC:-0}"
EOF
# ln fails when FAKE_LN_FAIL is set (a filesystem without hard links).
REAL_LN="$(command -v ln)"
cat > "${FAKE_BIN}/ln" <<EOF
#!/usr/bin/env bash
[ -n "\${FAKE_LN_FAIL:-}" ] && exit 1
exec "${REAL_LN}" "\$@"
EOF
chmod +x "${FAKE_BIN}/ln"
# cp fails for a copy to result.md (its temporary name) when FAKE_CP_FAIL is set.
REAL_CP="$(command -v cp)"
cat > "${FAKE_BIN}/cp" <<EOF
#!/usr/bin/env bash
if [ -n "\${FAKE_CP_FAIL:-}" ]; then
  case "\${@: -1}" in *result.md.*.tmp) exit 1 ;; esac
fi
exec "${REAL_CP}" "\$@"
EOF
chmod +x "${FAKE_BIN}/tmux" "${FAKE_BIN}/claude" "${FAKE_BIN}/cp"
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
RESULT_DIR=""   # where the wrapper under test wrote its result: its OUT_DIR
OUT=""
ERR=""
RC=0
UNSET_VARS=()
NO_TASK=""
TASK_TEXT="test task"

new_case() {
  CASE_N=$((CASE_N + 1))
  CASE_DIR="${ROOT}/case${CASE_N}"
  WORK_DIR="${CASE_DIR}/work"
  RESULT_DIR="$WORK_DIR"
  mkdir -p "$WORK_DIR"
  UNSET_VARS=()
  NO_TASK=""
  TASK_TEXT="test task"
  export FAKE_PANES_FILE="${CASE_DIR}/live-panes"
  export FAKE_TMUX_LOG="${CASE_DIR}/tmux.log"
  export FAKE_LIST_FAIL="${CASE_DIR}/list-panes-fails"
  export FAKE_CLAUDE_ARGV="${CASE_DIR}/claude-argv"
  export FAKE_CLAUDE_ENV="${CASE_DIR}/claude-env"
  export FAKE_WORK_DIR="$WORK_DIR"
  export FAKE_CLAUDE_RC=0
  export FAKE_LIST_DELAY=0
  unset FAKE_LIST_KILL FAKE_PANE_ID FAKE_CLAUDE_WRITE FAKE_CLAUDE_EMPTY FAKE_CLAUDE_SLEEP \
    FAKE_CLAUDE_LATE_WRITE FAKE_CLAUDE_LATE_DELAY \
    FAKE_TMUX_FAIL_ON FAKE_CP_FAIL FAKE_LN_FAIL CCORCH_PUBLISH_GRACE
  : > "$FAKE_PANES_FILE"
  : > "$FAKE_TMUX_LOG"
  live %99   # the fake current pane must be alive: the gate refuses otherwise
}

# Pane ids: the fake tmux reports the current pane as %99; fixtures use other ids.

live() { printf '%s\n' "$@" >> "$FAKE_PANES_FILE"; }
# only_live <ids...> — reset the live list to these ids plus the current pane
only_live() { : > "$FAKE_PANES_FILE"; live %99 "$@"; }

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

# run_wrapper <dry:1|0> <depth> [VAR=value ...] — sets OUT, ERR, RC and RESULT_DIR.
# Output goes to files, not to $(...): the wrapper's background sleeps would hold a pipe.
run_wrapper() {
  local dry="$1" depth="$2"; shift 2
  local task_args=("$TASK_TEXT") assigns=() kept=() unset_args=() a v skip
  if [ -n "$NO_TASK" ]; then task_args=(); fi
  assigns=(TMPDIR="${ROOT}/tmp" CCORCH_DEPTH="$depth" CCORCH_SESSION_ID=test
           CCORCH_PARENT_CHANNEL=test-channel CCORCH_WORK_DIR="$WORK_DIR"
           CCORCH_PROJECT_DIR="$ROOT" CCORCH_TIMEOUT=30)
  if [ "$dry" = 1 ]; then assigns+=(CCORCH_DRY_RUN=1); fi
  assigns+=("$@")
  # A variable the case wants unset is dropped from the assignments and from the
  # inherited environment (env stops reading options at the first NAME=VALUE).
  for a in "${assigns[@]}"; do
    skip=""
    for v in "${UNSET_VARS[@]+"${UNSET_VARS[@]}"}"; do
      case "$a" in "$v="*) skip=1 ;; esac
    done
    [ -n "$skip" ] || kept+=("$a")
  done
  for v in "${UNSET_VARS[@]+"${UNSET_VARS[@]}"}"; do unset_args+=(-u "$v"); done
  RC=0
  run_pg env -u CCORCH_PARENT_ID -u CCORCH_MAX_PANES -u TMUX_PANE -u CCORCH_LOCK_WAIT \
      -u CCORCH_MAX_CHILDREN_D1 -u CCORCH_MAX_CHILDREN_D2 -u CCORCH_DRY_RUN \
      "${unset_args[@]+"${unset_args[@]}"}" "${kept[@]}" \
      bash "$WRAPPER" "${task_args[@]+"${task_args[@]}"}" > "${CASE_DIR}/out" 2> "${CASE_DIR}/err" < /dev/null || RC=$?
  OUT=$(cat "${CASE_DIR}/out")
  ERR=$(cat "${CASE_DIR}/err")
  if [ "$dry" = 1 ]; then
    RESULT_DIR=$(sed -n '1s/^out_dir: //p' "${CASE_DIR}/out")
  else
    RESULT_DIR="$WORK_DIR"
  fi
}
run_dry()  { run_wrapper 1 "$@"; }
run_real() { run_wrapper 0 "$@"; }

# --- Assertion helpers ---

# result_path — the one result file of the wrapper under test; fails unless exactly one.
result_path() {
  local files=("${RESULT_DIR}"/depth*.md)
  [ "${#files[@]}" -eq 1 ] && [ -f "${files[0]}" ] || return 1
  printf '%s' "${files[0]}"
}
# result_has <fragment> — the one result file contains the fragment.
result_has() {
  local path
  path=$(result_path) || return 1
  grep -qF -- "$1" "$path"
}
# status_lines — number of `status:` lines at the start of a line in the one result file
status_lines() {
  local path
  path=$(result_path) || return 1
  grep -c '^status:' "$path"
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
# add_dir_is_out_dir — the element right after --add-dir is this run's OUT_DIR
add_dir_is_out_dir() {
  [ -n "$RESULT_DIR" ] && argv_elements | awk 'prev=="--add-dir"{print} {prev=$0}' | grep -qxF -- "$RESULT_DIR"
}
# add_dir_before_mode — --add-dir comes before --permission-mode (it takes several paths)
add_dir_before_mode() {
  argv_elements | awk '$0=="--add-dir"{a=NR} $0=="--permission-mode"{m=NR} END{exit !(a && m && a<m)}'
}

# file_is <path> <content> — a record holds exactly this content
file_is() { [ -f "$1" ] && [ "$(cat "$1")" = "$2" ]; }
no_files() { # no_files <glob...> — none of the globs matches an existing file
  local f
  for f in "$@"; do [ -e "$f" ] && return 1; done
  return 0
}
dir_is_empty() { [ -z "$(ls -A "$1")" ]; }
tmux_logged() { grep -qF -- "$1" "$FAKE_TMUX_LOG"; }
tmux_not_logged() { ! grep -qF -- "$1" "$FAKE_TMUX_LOG"; }
lock_gone() { [ ! -e "${WORK_DIR}/.lock.d" ]; }
claude_started() { [ -f "$FAKE_CLAUDE_ARGV" ]; }

# Rules every depth denies; depth 2 and 3 add the second list.
ALL_RULES=('Bash(rm -rf *)' 'Bash(rm -fr *)' 'Bash(rm -Rf *)' 'Bash(rm -r -f *)' 'Bash(rm -f -r *)'
           'Bash(rm -r --force *)' 'Bash(rm --recursive *)'
           'Bash(git push --force *)' 'Bash(git push *--force*)' 'Bash(git push -f *)'
           'Bash(git push * -f*)' 'Bash(git push * +*)' 'Bash(git push *--delete*)'
           'Bash(git push * :*)' 'Bash(git branch -D *)' 'Bash(git reset --hard *)'
           'Bash(git clean *)' 'Bash(sudo *)')
CHILD_RULES=('Bash(git push *)' 'Bash(git -C * push*)')

# --- Claude arguments at every depth ---

for depth in 1 2 3; do
  new_case
  [ "$depth" -gt 1 ] && seed_parent "$depth"
  if [ "$depth" -eq 1 ]; then run_dry 1; else run_dry "$depth" CCORCH_PARENT_ID=parent-1; fi
  expect "depth $depth: gate ok" gate_ok
  expect_not "depth $depth: no --dangerously-skip-permissions" argv_has '--dangerously-skip-permissions'
  expect_not "depth $depth: no --allowedTools" argv_has '--allowedTools'
  expect "depth $depth: auto follows --permission-mode" mode_is_auto
  expect "depth $depth: --add-dir gives the session directory" add_dir_is_out_dir
  expect "depth $depth: --add-dir comes before --permission-mode" add_dir_before_mode
  for rule in "${ALL_RULES[@]}"; do
    expect "depth $depth: deny rule '$rule' between the flags" has_deny "$rule"
  done
  for rule in "${CHILD_RULES[@]}"; do
    if [ "$depth" -ge 2 ]; then
      expect "depth $depth: deny rule '$rule' between the flags" has_deny "$rule"
    else
      expect_not "depth 1: no deny rule '$rule'" has_deny "$rule"
    fi
  done
done

# --- Per-depth differences ---

new_case; seed_parent 3; run_dry 3 CCORCH_PARENT_ID=parent-1
expect "depth 3: Agent denied" has_deny 'Agent'
expect "depth 3: Bash(tmux *) denied" has_deny 'Bash(tmux *)'

new_case; seed_parent 2; run_dry 2 CCORCH_PARENT_ID=parent-1
expect_not "depth 2: Agent not denied" has_deny 'Agent'
expect_not "depth 2: tmux not denied" has_deny 'Bash(tmux *)'

new_case; run_dry 1
expect_not "depth 1: Agent not denied" has_deny 'Agent'
expect_not "depth 1: tmux not denied" has_deny 'Bash(tmux *)'
expect "depth 1 without CCORCH_PARENT_ID: gate ok" gate_ok

# An inherited DERIVED_DEPTH must not set the depth (it is derived, never read from the environment).
new_case; run_dry 1 DERIVED_DEPTH=2
expect "depth 1 with DERIVED_DEPTH=2 in the environment: still depth 1" gate_ok
expect_not "depth 1 with DERIVED_DEPTH=2 in the environment: no depth-2 deny rule" has_deny 'Bash(git push *)'

# --- Depth range ---

new_case; run_dry 4 CCORCH_PARENT_ID=parent-1
expect "depth 4: refused, result has status: refused" refused_with "CCORCH_DEPTH must be 1, 2 or 3"

new_case; run_dry abc
expect "depth 'abc': refused" refused_with "CCORCH_DEPTH must be 1, 2 or 3"

new_case; run_dry '../../x'
expect "depth '../../x': refused, result stays in the output directory" refused_with "CCORCH_DEPTH must be 1, 2 or 3"

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

new_case; seed_parent 2; only_live
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

new_case; seed_pane main-1 %21 1; only_live
run_dry 1
expect "depth 1 after a dead Main Brain: ok" gate_ok

# --- Limits and timeout must be positive integers ---

for var in CCORCH_MAX_PANES CCORCH_MAX_CHILDREN_D1 CCORCH_MAX_CHILDREN_D2 CCORCH_TIMEOUT; do
  new_case; run_dry 1 "${var}=abc"
  expect "${var}=abc: refused, names the variable" refused_with "${var} must be a positive integer"
  new_case; run_dry 1 "${var}=0"
  expect "${var}=0: refused" refused_with "${var} must be a positive integer"
done
for var in CCORCH_MAX_PANES CCORCH_MAX_CHILDREN_D1 CCORCH_MAX_CHILDREN_D2; do
  new_case; run_dry 1 "${var}="
  expect "${var} empty: treated as unset, the default applies" gate_ok
done

# --- Values in the result file cannot add a status line ---

new_case; run_dry 1 $'CCORCH_MAX_PANES=abc\nstatus: success'
expect "newline injected through a limit: refused" refused_with "CCORCH_MAX_PANES must be a positive integer"
expect "newline injected through a limit: exactly one status: line" test "$(status_lines)" = 1
expect "newline injected through a limit: the status is refused" result_has 'status: refused'

new_case; run_dry $'1\nstatus: success'
expect "newline injected through the depth: exactly one status: line" test "$(status_lines)" = 1

new_case; TASK_TEXT=$'a task\nstatus: success'; run_dry 1 CCORCH_MAX_PANES=abc
expect "newline in the task: exactly one status: line" test "$(status_lines)" = 1

# --- tmux failures and the pane id fail closed ---

new_case; touch "$FAKE_LIST_FAIL"
record_pane depthA-1 %11
run_dry 1
expect "list-panes fails: refused, not counted as dead" refused_with "tmux list-panes failed"

new_case; export FAKE_PANE_ID=; run_dry 1
expect "empty pane id: refused" refused_with "cannot determine this pane's tmux id"

new_case; export FAKE_PANE_ID=%77; run_dry 1
expect "pane id not in the pane list: refused" refused_with "%77) is not in the tmux pane list"

# --- Pane limit (children limits are not involved at depth 1) ---

new_case; record_pane depthA-1 %11; record_pane depthA-2 %12
run_dry 1 CCORCH_MAX_PANES=3
expect "MAX_PANES=3, 2 live recorded: ok" gate_ok

new_case; record_pane depthA-1 %11; record_pane depthA-2 %12; record_pane depthA-3 %13
run_dry 1 CCORCH_MAX_PANES=3
expect "MAX_PANES=3, 3 live recorded: refused (pane limit)" refused_with "pane limit reached"

new_case; record_pane depthA-1 %11; record_pane depthA-2 %12; record_pane depthA-3 %13
only_live %11 %12   # %13 is dead
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
only_live %21 %11   # %12 is dead
run_dry 2 CCORCH_PARENT_ID=parent-1 CCORCH_MAX_CHILDREN_D1=2 CCORCH_MAX_PANES=20
expect "a dead sibling is not counted: ok" gate_ok

# --- Dry run leaves no trace in the live session ---

new_case; run_dry 1
expect "dry run: the live WORK_DIR has no new file" dir_is_empty "$WORK_DIR"
expect "dry run: the output directory holds the result, status.md and the prompt" \
  bash -c 'ls "$1"/depth*.md "$1"/status.md "$1"/*.dry-run.system-prompt >/dev/null 2>&1' _ "$RESULT_DIR"
expect "dry run: result file says status: dry-run" result_has 'status: dry-run'
expect "dry run: claude not started" test ! -e "$FAKE_CLAUDE_ARGV"
expect "dry run: parent channel not signalled" tmux_not_logged "wait-for"

new_case; WORK_DIR="${CASE_DIR}/never-created"; run_dry 1
expect "dry run: a missing WORK_DIR is not created" test ! -e "$WORK_DIR"

new_case; seed_pane main-1 %21 1; run_dry 1
expect "refused dry run: the live WORK_DIR still has only the seeded files" \
  bash -c 'test "$(ls -A "$1" | wc -l)" -eq 2' _ "$WORK_DIR"

# --- Records: written by a real start only ---

new_case; seed_parent 2
run_real 2 CCORCH_PARENT_ID=parent-1
ID=$(child_id)
expect "real start: wrapper exits 0" test "$RC" -eq 0
expect "real start: .pane holds the current pane id" file_is "${WORK_DIR}/${ID}.pane" '%99'
expect "real start: .parent holds the parent id" file_is "${WORK_DIR}/${ID}.parent" 'parent-1'
expect "real start: .depth holds the depth" file_is "${WORK_DIR}/${ID}.depth" '2'
expect "real start: claude was started" claude_started
expect "real start: --add-dir gives the live session directory" \
  bash -c 'awk "prev==\"--add-dir\"{print} {prev=\$0}" "$1" | grep -qxF -- "$2"' _ "$FAKE_CLAUDE_ARGV" "$WORK_DIR"
expect "real start: lock released" lock_gone
expect "real start: a child's result is not copied to result.md" test ! -e "${WORK_DIR}/result.md"

# --- Refusal in a real start signals the parent and never reaches claude ---

new_case; run_real 4 CCORCH_PARENT_ID=parent-1
expect "real start, depth 4: refused with status: refused" refused_with "CCORCH_DEPTH must be 1, 2 or 3"
expect "real start, depth 4: parent channel signalled" tmux_logged 'wait-for -S test-channel'
expect "real start, depth 4: claude not reached" test ! -e "$FAKE_CLAUDE_ARGV"

# --- Failures before the gate still reach the parent ---

new_case; run_real 1 CCORCH_PROJECT_DIR="${ROOT}/does-not-exist"
expect "missing PROJECT_DIR directory: refused" refused_with "CCORCH_PROJECT_DIR is not a directory"
expect "missing PROJECT_DIR directory: parent signalled" tmux_logged 'wait-for -S test-channel'

new_case; UNSET_VARS=(CCORCH_PROJECT_DIR); run_real 1
expect "unset PROJECT_DIR: refused, parent signalled" refused_with "CCORCH_PROJECT_DIR is required"
expect "unset PROJECT_DIR: parent channel signalled" tmux_logged 'wait-for -S test-channel'

new_case; UNSET_VARS=(CCORCH_SESSION_ID); run_real 1
expect "unset SESSION_ID: refused" refused_with "CCORCH_SESSION_ID is required"

new_case; NO_TASK=1; run_real 1
expect "missing task argument: refused, parent signalled" refused_with "the task argument is missing"
expect "missing task argument: parent channel signalled" tmux_logged 'wait-for -S test-channel'

new_case; UNSET_VARS=(CCORCH_WORK_DIR); run_real 1
expect "unset WORK_DIR: exit 2" test "$RC" -eq 2
expect "unset WORK_DIR: message on stderr" bash -c 'grep -q CCORCH_WORK_DIR <<< "$1"' _ "$ERR"
expect "unset WORK_DIR: no signal is possible, none sent" tmux_not_logged 'wait-for'

new_case; UNSET_VARS=(CCORCH_PARENT_CHANNEL); run_real 1
expect "unset PARENT_CHANNEL: exit 2" test "$RC" -eq 2

# --- The Main Brain's result reaches the user's session as result.md ---

new_case; run_real 1 CCORCH_MAX_PANES=abc
expect "Main Brain refusal: result.md holds the refusal" grep -qF 'status: refused' "${WORK_DIR}/result.md"

new_case; run_real 1
expect "Main Brain ends without a result file: result.md says incomplete" grep -qF 'status: incomplete' "${WORK_DIR}/result.md"

new_case; seed_pane main-1 %21 1; run_real 1
expect "refusal because a Main Brain is running: result.md is not planted" test ! -e "${WORK_DIR}/result.md"

new_case; run_real 2
expect "a child's refusal does not write result.md" test ! -e "${WORK_DIR}/result.md"

# A stale result.md (an earlier hook copy) is replaced when the result file was rewritten.
# The comparison is by content, so this holds within the same second as the old copy.
new_case
printf 'old copy\n' > "${WORK_DIR}/result.md"
run_real 1 FAKE_CLAUDE_WRITE='final result'
expect "result rewritten after the hook's copy: result.md holds the final result" \
  file_is "${WORK_DIR}/result.md" 'final result'
expect "wrapper's copy leaves no temporary file" no_files "${WORK_DIR}"/result.md.*.tmp

# A Main Brain refused before claude starts never replaces an existing result.md: it may be
# the real result of another Main Brain in this session.
new_case; printf 'real result\n' > "${WORK_DIR}/result.md"; touch "$FAKE_LIST_FAIL"
run_real 1
expect "refused at list-panes with result.md present: refused" refused_with "tmux list-panes failed"
expect "refused at list-panes with result.md present: result.md untouched" file_is "${WORK_DIR}/result.md" 'real result'

new_case; printf 'real result\n' > "${WORK_DIR}/result.md"
sleep 60 & LOCK_OWNER=$!
mkdir "${WORK_DIR}/.lock.d"; printf '%s\n' "$LOCK_OWNER" > "${WORK_DIR}/.lock.d/owner"
run_real 1 CCORCH_LOCK_WAIT=1
kill "$LOCK_OWNER" 2>/dev/null; wait "$LOCK_OWNER" 2>/dev/null
expect "refused at the lock with result.md present: refused" refused_with "lock timeout"
expect "refused at the lock with result.md present: result.md untouched" file_is "${WORK_DIR}/result.md" 'real result'

# An empty result file counts as no result: the wrapper writes its own, and result.md gets it.
new_case; run_real 1 FAKE_CLAUDE_EMPTY=1
expect "empty result file: the wrapper writes status: incomplete" result_has 'status: incomplete'
expect "empty result file: result.md is not empty" test -s "${WORK_DIR}/result.md"

# --- The Stop hook's environment ---

new_case; run_real 1
expect "Main Brain: claude gets CCORCH_COPY_RESULT=1" grep -qxF 'CCORCH_COPY_RESULT=1' "$FAKE_CLAUDE_ENV"
expect "Main Brain: claude gets its result file" grep -qxF "CCORCH_RESULT_FILE=${WORK_DIR}/$(child_id).md" "$FAKE_CLAUDE_ENV"

new_case; seed_parent 2; run_real 2 CCORCH_PARENT_ID=parent-1
expect "child: claude gets an empty CCORCH_COPY_RESULT" grep -qxF 'CCORCH_COPY_RESULT=' "$FAKE_CLAUDE_ENV"

# --- claude's exit status is not discarded ---

new_case; export FAKE_CLAUDE_RC=3; run_real 1
expect "claude exits 3, no result file: status: error" result_has 'status: error'
expect "claude exits 3, no result file: exit code recorded" result_has 'exit_code: 3'
expect_not "claude exits 3, no result file: not success" result_has 'status: success'

new_case; run_real 1
expect "claude exits 0, no result file: status: incomplete" result_has 'status: incomplete'
expect_not "claude exits 0, no result file: not success" result_has 'status: success'

# --- A large task does not abort the wrapper ---

new_case; TASK_TEXT="$(head -c 110000 /dev/zero | tr '\0' 'a')"$'\nsecond line'
run_real 1
expect "a task of about 110 KB: wrapper exits 0" test "$RC" -eq 0
expect "a task of about 110 KB: claude was started" claude_started
expect "a task of about 110 KB: result file written" result_has 'status: incomplete'

# --- Lock: released on every exit path that holds it ---

new_case; record_pane depthA-1 %11; record_pane depthA-2 %12; record_pane depthA-3 %13
run_real 1 CCORCH_MAX_PANES=3
expect "pane limit refusal under the lock: refused" refused_with "pane limit reached"
expect "pane limit refusal under the lock: lock released" lock_gone

new_case; seed_parent 2
record_pane depthB-1 %11 parent-1; record_pane depthB-2 %12 parent-1
run_real 2 CCORCH_PARENT_ID=parent-1 CCORCH_MAX_CHILDREN_D1=2 CCORCH_MAX_PANES=20
expect "children limit refusal under the lock: refused" refused_with "CCORCH_MAX_CHILDREN_D1=2"
expect "children limit refusal under the lock: lock released" lock_gone

new_case; touch "$FAKE_LIST_FAIL"; run_real 1
expect "list-panes failure under the lock: refused" refused_with "tmux list-panes failed"
expect "list-panes failure under the lock: lock released" lock_gone

new_case; seed_parent 2; run_real 3 CCORCH_PARENT_ID=parent-1
expect "depth mismatch under the lock: refused" refused_with "disagrees"
expect "depth mismatch under the lock: lock released" lock_gone

# A non-refusal exit while holding the lock: the wrapper gets SIGTERM during list-panes.
# Only cleanup() can release the lock and signal the parent here.
new_case; export FAKE_LIST_KILL=1; run_real 1
expect "TERM while holding the lock: lock released by cleanup()" lock_gone
expect "TERM while holding the lock: result says status: error" result_has 'status: error'
expect "TERM while holding the lock: parent channel signalled" tmux_logged 'wait-for -S test-channel'

# --- Lock: three children start at once; the limit must hold ---
# list-panes is slow (inside the lock), so without the lock all three would count zero
# siblings and pass.

launch_child() { # launch_child <n> — a real depth-2 start with its own pane id and files
  local n="$1"
  (
    RCN=0
    run_pg env -u CCORCH_DRY_RUN -u TMUX_PANE -u CCORCH_LOCK_WAIT TMPDIR="${ROOT}/tmp" CCORCH_DEPTH=2 CCORCH_SESSION_ID=test \
      CCORCH_PARENT_CHANNEL=test-channel CCORCH_WORK_DIR="$WORK_DIR" CCORCH_PROJECT_DIR="$ROOT" \
      CCORCH_TIMEOUT=30 CCORCH_PARENT_ID=parent-1 CCORCH_MAX_PANES=9 CCORCH_MAX_CHILDREN_D1=2 \
      FAKE_PANE_ID="%3${n}" FAKE_CLAUDE_ARGV="${CASE_DIR}/claude-argv.${n}" \
      bash "$WRAPPER" 'test task' > "${CASE_DIR}/out.${n}" 2> "${CASE_DIR}/err.${n}" < /dev/null || RCN=$?
    echo "$RCN" > "${CASE_DIR}/rc.${n}"
  ) &
}

new_case; seed_parent 2; live %31 %32 %33
export FAKE_LIST_DELAY=0.5
launch_child 1; launch_child 2; launch_child 3
wait
PASSED=0; REFUSED=0
for n in 1 2 3; do
  case "$(cat "${CASE_DIR}/rc.${n}")" in
    0) PASSED=$((PASSED + 1)) ;;
    1) REFUSED=$((REFUSED + 1)); REFUSED_ERR="$(cat "${CASE_DIR}/err.${n}")" ;;
  esac
done
expect "three simultaneous children, D1=2: exactly 2 pass" test "$PASSED" -eq 2
expect "three simultaneous children, D1=2: exactly 1 is refused" test "$REFUSED" -eq 1
expect "three simultaneous children, D1=2: the refusal names CCORCH_MAX_CHILDREN_D1" \
  bash -c 'grep -qF CCORCH_MAX_CHILDREN_D1 <<< "$1"' _ "${REFUSED_ERR:-}"
expect "three simultaneous children: lock released" lock_gone

# --- Lock: a lock that is held, or left behind, ends in a refusal naming it ---
# There is no automatic recovery: the wait is bounded (CCORCH_LOCK_WAIT), then refused.

new_case; sleep 60 & LIVE_OWNER=$!
mkdir "${WORK_DIR}/.lock.d"; printf '%s\n' "$LIVE_OWNER" > "${WORK_DIR}/.lock.d/owner"
run_real 1 CCORCH_LOCK_WAIT=1
expect "lock held by a live pid: refused" refused_with "lock timeout"
expect "lock held by a live pid: the reason names the lock directory" refused_with "${WORK_DIR}/.lock.d"
expect "lock held by a live pid: the reason names the owner pid" refused_with "owner pid ${LIVE_OWNER}"
expect "lock held by a live pid: the reason says to remove it" refused_with "remove this directory and retry"
expect "lock held by a live pid: left as it was" file_is "${WORK_DIR}/.lock.d/owner" "$LIVE_OWNER"
expect "lock held by a live pid: parent signalled" tmux_logged 'wait-for -S test-channel'
expect_not "lock held by a live pid: claude not started" claude_started
kill "$LIVE_OWNER" 2>/dev/null; wait "$LIVE_OWNER" 2>/dev/null

new_case; sleep 0 & DEAD_PID=$!; wait "$DEAD_PID"
mkdir "${WORK_DIR}/.lock.d"; printf '%s\n' "$DEAD_PID" > "${WORK_DIR}/.lock.d/owner"
run_real 1 CCORCH_LOCK_WAIT=1
expect "lock left by a dead pid: not recovered, refused" refused_with "lock timeout"
expect "lock left by a dead pid: left as it was" file_is "${WORK_DIR}/.lock.d/owner" "$DEAD_PID"

new_case; mkdir "${WORK_DIR}/.lock.d"
run_real 1 CCORCH_LOCK_WAIT=1
expect "lock with no owner file: refused, the reason names it" refused_with "${WORK_DIR}/.lock.d"
expect "lock with no owner file: left in place" test -d "${WORK_DIR}/.lock.d"

new_case; run_dry 1 CCORCH_LOCK_WAIT=0
expect "CCORCH_LOCK_WAIT=0: refused" refused_with "CCORCH_LOCK_WAIT must be a positive integer"
new_case; run_dry 1 CCORCH_LOCK_WAIT=abc
expect "CCORCH_LOCK_WAIT=abc: refused" refused_with "CCORCH_LOCK_WAIT must be a positive integer"
new_case; run_dry 1 CCORCH_LOCK_WAIT=1000000
expect "CCORCH_LOCK_WAIT with 7 digits: refused" refused_with "at most 6 digits"
new_case; run_dry 1 CCORCH_MAX_PANES=1000000
expect "CCORCH_MAX_PANES with 7 digits: refused" refused_with "at most 6 digits"
new_case; run_dry 1 CCORCH_MAX_PANES=999999
expect "CCORCH_MAX_PANES with 6 digits: accepted" gate_ok

# --- The parent is signalled even when nothing can be written ---
# A read-only work directory: the lock cannot be taken (mkdir fails), the refusal cannot be
# written, and cleanup() cannot write a result. The signal must still go out.

if [ "$(id -u)" -eq 0 ]; then
  echo "NOTE: running as root, chmod does not bind root: skipping the read-only work directory case"
else
  new_case; chmod 555 "$WORK_DIR"
  START=$SECONDS
  run_real 1 CCORCH_LOCK_WAIT=1
  ELAPSED=$((SECONDS - START))
  chmod 755 "$WORK_DIR"
  expect "read-only work directory: exit code 1" test "$RC" -eq 1
  expect "read-only work directory: parent channel signalled" tmux_logged 'wait-for -S test-channel'
  expect "read-only work directory: no record or result written" \
    no_files "${WORK_DIR}"/*.pane "${WORK_DIR}"/*.parent "${WORK_DIR}"/*.depth "${WORK_DIR}"/*.md
  expect "read-only work directory: finished in under 5 s (CCORCH_LOCK_WAIT honoured)" test "$ELAPSED" -lt 5
fi

# --- This pane is the one $TMUX_PANE names, not the active pane ---

new_case; live %77 %active
run_real 1 TMUX_PANE=%77 FAKE_PANE_ID=%active
expect "TMUX_PANE=%77: wrapper exits 0" test "$RC" -eq 0
expect "TMUX_PANE=%77: the recorded .pane holds %77" file_is "${WORK_DIR}/$(child_id).pane" %77

# --- System prompt ---

new_case; run_dry 1 CCORCH_MAX_PANES=5 CCORCH_MAX_CHILDREN_D1=2 CCORCH_MAX_CHILDREN_D2=1
ID=$(child_id)
PROMPT_FILE="${RESULT_DIR}/${ID}.dry-run.system-prompt"
for needle in 'CCORCH_MAX_PANES=5' 'CCORCH_MAX_CHILDREN_D1=2' 'CCORCH_MAX_CHILDREN_D2=1' "CCORCH_PARENT_ID=${ID} "; do
  expect "depth 1 prompt: split-pane template has ${needle}" grep -qF -- "$needle" "$PROMPT_FILE"
done

new_case; seed_parent 2
run_dry 2 CCORCH_PARENT_ID=parent-1 CCORCH_MAX_PANES=5 CCORCH_MAX_CHILDREN_D1=2 CCORCH_MAX_CHILDREN_D2=1
ID=$(child_id)
PROMPT_FILE="${RESULT_DIR}/${ID}.dry-run.system-prompt"
for needle in 'CCORCH_MAX_PANES=5' 'CCORCH_MAX_CHILDREN_D1=2' 'CCORCH_MAX_CHILDREN_D2=1' "CCORCH_PARENT_ID=${ID} "; do
  expect "depth 2 prompt: split-pane template has ${needle}" grep -qF -- "$needle" "$PROMPT_FILE"
done

# Files are written with the Write tool: a user's ask rule on mv would stop the pane.
new_case; run_dry 1
PROMPT_FILE="${RESULT_DIR}/$(child_id).dry-run.system-prompt"
expect_not "depth 1 prompt: no 'mv \"' instruction" grep -qF 'mv "' "$PROMPT_FILE"
expect_not "depth 1 prompt: no temporary .tmp file" grep -qF '.tmp' "$PROMPT_FILE"
expect "depth 1 prompt: files are written with the Write tool" grep -qF 'with the Write tool' "$PROMPT_FILE"
expect "depth 1 prompt: the result file is written once, at the end" grep -qF 'once, at the end' "$PROMPT_FILE"
expect "depth 1 prompt: cleanup skips the Main Brain's own pane" grep -qF 'Never close your own pane' "$PROMPT_FILE"
expect "depth 1 prompt: a signal without a result file means wait again" grep -qF 'wait on its channel again' "$PROMPT_FILE"

new_case; seed_parent 2; run_dry 2 CCORCH_PARENT_ID=parent-1
PROMPT_FILE="${RESULT_DIR}/$(child_id).dry-run.system-prompt"
expect "depth 2 prompt: cleanup comes before the result, not of its own pane" grep -qF 'never your own' "$PROMPT_FILE"
expect "depth 2 prompt: a signal without a result file means wait again" grep -qF 'wait on its channel again' "$PROMPT_FILE"
expect_not "depth 2 prompt: no 'mv \"' instruction" grep -qF 'mv "' "$PROMPT_FILE"

# --- Stop hook: the Main Brain signals only once its result exists; others every turn ---

HOOK="${HERE}/../hooks/stop_signal.sh"

# run_hook [VAR=value ...] — the hook with only the given ccorch variables set.
run_hook() {
  env -u CCORCH_PARENT_CHANNEL -u CCORCH_RESULT_FILE -u CCORCH_COPY_RESULT -u CCORCH_WORK_DIR \
    "$@" bash "$HOOK" < /dev/null
}
signalled() { grep -qxF 'wait-for -S test-channel' "$FAKE_TMUX_LOG"; }

new_case; run_hook
expect_not "hook outside ccorch: no signal" signalled

# run_mb_hook — the hook as the session's Main Brain, with its result file at r.md.
run_mb_hook() {
  run_hook CCORCH_PARENT_CHANNEL=test-channel CCORCH_RESULT_FILE="${WORK_DIR}/r.md" \
    CCORCH_COPY_RESULT=1 CCORCH_WORK_DIR="$WORK_DIR"
}

new_case; run_mb_hook
expect_not "hook, Main Brain, result file absent: no signal" signalled
expect "hook, Main Brain, result file absent: no result.md" test ! -e "${WORK_DIR}/result.md"

new_case; : > "${WORK_DIR}/r.md"; run_mb_hook
expect_not "hook, Main Brain, result file empty: no signal" signalled
expect "hook, Main Brain, result file empty: no result.md" test ! -e "${WORK_DIR}/result.md"

# A child signals at every turn, with or without a result, so a stuck child still wakes
# its parent; it never writes result.md.
new_case
run_hook CCORCH_PARENT_CHANNEL=test-channel CCORCH_RESULT_FILE="${WORK_DIR}/r.md" CCORCH_COPY_RESULT= CCORCH_WORK_DIR="$WORK_DIR"
expect "hook, child, no result yet: signals the parent" signalled
expect "hook, child: no result.md" test ! -e "${WORK_DIR}/result.md"

new_case; run_hook CCORCH_PARENT_CHANNEL=test-channel
expect "hook from an older wrapper (no CCORCH_RESULT_FILE): signals as before" signalled

new_case; printf 'first\n' > "${WORK_DIR}/r.md"; run_mb_hook
expect "hook, Main Brain: result.md is a copy of the result file" cmp -s "${WORK_DIR}/r.md" "${WORK_DIR}/result.md"
expect "hook, Main Brain: signals after copying" signalled
expect "hook, Main Brain: no temporary file left" no_files "${WORK_DIR}"/result.md.*.tmp
printf 'second\n' > "${WORK_DIR}/r.md"; run_mb_hook
expect "hook, Main Brain rewrote its result: result.md follows" file_is "${WORK_DIR}/result.md" 'second'

# A failed copy must not wake the user's session: result.md would be missing or older.
new_case; printf 'first\n' > "${WORK_DIR}/r.md"; FAKE_CP_FAIL=1 run_mb_hook
expect_not "hook, Main Brain, copy fails: no signal" signalled
expect "hook, Main Brain, copy fails: no result.md" test ! -e "${WORK_DIR}/result.md"
expect "hook, Main Brain, copy fails: no temporary file left" no_files "${WORK_DIR}"/result.md.*.tmp

new_case; printf 'old\n' > "${WORK_DIR}/result.md"; printf 'new\n' > "${WORK_DIR}/r.md"
FAKE_CP_FAIL=1 run_mb_hook
expect_not "hook, Main Brain, copy fails over an older result.md: no signal" signalled

new_case; FAKE_CP_FAIL=1 run_hook CCORCH_PARENT_CHANNEL=test-channel CCORCH_RESULT_FILE="${WORK_DIR}/r.md" CCORCH_COPY_RESULT= CCORCH_WORK_DIR="$WORK_DIR"
expect "hook, child, cp failing: still signals (a child copies nothing)" signalled

# --- The wrapper's cleanup: a failed copy removes an older result.md ---

new_case; printf 'old copy\n' > "${WORK_DIR}/result.md"
run_real 1 FAKE_CLAUDE_WRITE='final result' FAKE_CP_FAIL=1
expect "cleanup copy fails: the older result.md is removed" test ! -e "${WORK_DIR}/result.md"
expect "cleanup copy fails: the result file is kept" result_has 'final result'
expect "cleanup copy fails: the parent is still signalled" tmux_logged 'wait-for -S test-channel'

new_case; printf 'final result\n' > "${WORK_DIR}/result.md"
run_real 1 FAKE_CLAUDE_WRITE='final result' FAKE_CP_FAIL=1
expect "cleanup with result.md already equal: nothing to copy, result.md kept" file_is "${WORK_DIR}/result.md" 'final result'

new_case; printf 'real result\n' > "${WORK_DIR}/result.md"; touch "$FAKE_LIST_FAIL"
run_real 1 FAKE_CP_FAIL=1
expect "refused before claude, cp failing: result.md untouched" file_is "${WORK_DIR}/result.md" 'real result'

# --- publish_if_absent (scripts/ccorch-lib.sh) ---

LIB="${HERE}/../scripts/ccorch-lib.sh"
# publish <tmp content> — runs publish_if_absent on ${CASE_DIR}/tmp -> ${CASE_DIR}/target; sets PUB_RC
publish() {
  printf '%s\n' "$1" > "${CASE_DIR}/tmp"
  PUB_RC=0
  ( . "$LIB"; publish_if_absent "${CASE_DIR}/tmp" "${CASE_DIR}/target" ) || PUB_RC=$?
}

new_case; printf 'pane result\n' > "${CASE_DIR}/target"; publish 'timeout'
expect "publish over a result: returns 1" test "$PUB_RC" = 1
expect "publish over a result: the result is untouched" file_is "${CASE_DIR}/target" 'pane result'
expect "publish over a result: the temporary file is removed" test ! -e "${CASE_DIR}/tmp"

new_case; publish 'timeout'
expect "publish with no result: returns 0" test "$PUB_RC" = 0
expect "publish with no result: the target holds it" file_is "${CASE_DIR}/target" 'timeout'
expect "publish with no result: the temporary file is gone" test ! -e "${CASE_DIR}/tmp"

new_case; : > "${CASE_DIR}/target"; CCORCH_PUBLISH_GRACE=0 publish 'timeout'
expect "publish over an empty file that stays empty: replaced" file_is "${CASE_DIR}/target" 'timeout'

new_case; : > "${CASE_DIR}/target"
( sleep 0.3; printf 'pane result\n' > "${CASE_DIR}/target" ) &
CCORCH_PUBLISH_GRACE=2 publish 'timeout'; wait
expect "publish over an empty file filled during the grace: returns 1" test "$PUB_RC" = 1
expect "publish over an empty file filled during the grace: the pane's result stays" file_is "${CASE_DIR}/target" 'pane result'

# Without hard links, an absent target is still published, and a result is still kept.
new_case; FAKE_LN_FAIL=1 publish 'timeout'
expect "publish, ln unavailable, no result: returns 0" test "$PUB_RC" = 0
expect "publish, ln unavailable, no result: the target holds it" file_is "${CASE_DIR}/target" 'timeout'

new_case; printf 'pane result\n' > "${CASE_DIR}/target"; FAKE_LN_FAIL=1 publish 'timeout'
expect "publish, ln unavailable, over a result: returns 1" test "$PUB_RC" = 1
expect "publish, ln unavailable, over a result: untouched" file_is "${CASE_DIR}/target" 'pane result'
expect "publish, ln unavailable, over a result: the temporary file is removed" test ! -e "${CASE_DIR}/tmp"

# --- Watchdog ---

new_case; run_real 1 CCORCH_TIMEOUT=1 FAKE_CLAUDE_SLEEP=5
expect "watchdog, no result: status: timeout" result_has 'status: timeout'
expect "watchdog, no result: the pane is stopped" test ! -e "${FAKE_CLAUDE_ARGV}.slept"

new_case; run_real 1 CCORCH_TIMEOUT=1 CCORCH_PUBLISH_GRACE=1 FAKE_CLAUDE_EMPTY=1 FAKE_CLAUDE_SLEEP=5
expect "watchdog, empty result file: status: timeout after the grace" result_has 'status: timeout'
expect "watchdog, empty result file: the pane is stopped" test ! -e "${FAKE_CLAUDE_ARGV}.slept"

# Not the race itself (that is closed by ln in publish_if_absent, tested above): a pane that
# finished before the timeout keeps its result and is not stopped.
new_case; run_real 1 CCORCH_TIMEOUT=1 FAKE_CLAUDE_WRITE='final result' FAKE_CLAUDE_SLEEP=2
expect "watchdog, result already written: the result stays" result_has 'final result'
expect "watchdog, result already written: the pane is not stopped" test -e "${FAKE_CLAUDE_ARGV}.slept"

# The watchdog's publish fails (the result arrives during the grace on an empty file): the
# timeout is not written and the pane is not stopped.
new_case; run_real 1 CCORCH_TIMEOUT=1 CCORCH_PUBLISH_GRACE=3 FAKE_CLAUDE_EMPTY=1 \
  FAKE_CLAUDE_LATE_WRITE='late result' FAKE_CLAUDE_LATE_DELAY=2 FAKE_CLAUDE_SLEEP=3
expect "watchdog, result written during the grace: the pane's result stays" result_has 'late result'
expect_not "watchdog, result written during the grace: no timeout result" result_has 'status: timeout'
expect "watchdog, result written during the grace: the pane is not stopped" test -e "${FAKE_CLAUDE_ARGV}.slept"

# --- tmux pane-died hook: armed before claude, disarmed by the cleanup ---

SCRIPTS_ABS="$(cd "${HERE}/../scripts" && pwd)"
# log_line <fragment> — line number of the first tmux log line with the fragment (0 if none)
log_line() { grep -nF -- "$1" "$FAKE_TMUX_LOG" | head -1 | cut -d: -f1 | grep . || echo 0; }
# before <a> <b> — the fragment a is logged, and before b
before() { local a b; a=$(log_line "$1"); b=$(log_line "$2"); [ "$a" -gt 0 ] && [ "$b" -gt 0 ] && [ "$a" -lt "$b" ]; }

new_case; run_real 1 FAKE_CLAUDE_WRITE='final result'
ID=$(child_id)
expect "hook: remain-on-exit is set on this pane" tmux_logged 'set-option -p -t %99 remain-on-exit on'
expect "hook: pane-died writes the result, then signals, then closes the pane" \
  tmux_logged "set-hook -p -t %99 pane-died run-shell 'bash ${SCRIPTS_ABS}/ccorch-pane-died.sh ${WORK_DIR}/${ID}.md ${WORK_DIR} 1 1' ; wait-for -S test-channel ; kill-pane -t %99"
expect "hook: the cleanup unsets remain-on-exit" tmux_logged 'set-option -u -p -t %99 remain-on-exit'
expect "hook: the cleanup unsets the hook" tmux_logged 'set-hook -u -p -t %99 pane-died'
expect "hook: unset in order, option first" before 'set-option -u -p' 'set-hook -u -p'
# The armed hook's text also contains "wait-for -S", so the signal is matched as a whole line.
signal_line() { grep -nxF 'wait-for -S test-channel' "$FAKE_TMUX_LOG" | head -1 | cut -d: -f1 | grep . || echo 0; }
expect "hook: disarmed before the trap's signal" \
  test "$(log_line 'set-hook -u -p')" -gt 0 -a "$(log_line 'set-hook -u -p')" -lt "$(signal_line)"
expect "hook: one signal on a normal exit (from the trap)" test "$(grep -cxF 'wait-for -S test-channel' "$FAKE_TMUX_LOG")" = 1

new_case; seed_parent 2; run_real 2 CCORCH_PARENT_ID=parent-1
expect "hook, child: no copy to result.md, depth 2" tmux_logged "${WORK_DIR}/$(child_id).md ${WORK_DIR} 0 2'"

new_case; run_dry 1
expect "hook: a dry run sets none" tmux_not_logged 'remain-on-exit'
expect "hook: a dry run sets no pane-died hook" tmux_not_logged 'pane-died'

new_case; run_real 1 CCORCH_MAX_PANES=abc
expect "hook: a refusal sets none" tmux_not_logged 'remain-on-exit'

new_case; run_real 1 'CCORCH_PARENT_CHANNEL=bad;channel'
expect "hook: a channel that is not plain sets none" tmux_not_logged 'remain-on-exit'
expect "hook: a channel that is not plain still starts claude" claude_started

new_case; run_real 1 'CCORCH_PARENT_CHANNEL=-x'
expect "hook: a channel starting with - sets none" tmux_not_logged 'remain-on-exit'

new_case; live 123; run_real 1 FAKE_PANE_ID=123 TMUX_PANE=123
expect "hook: a pane id without % sets none" tmux_not_logged 'remain-on-exit'

# If remain-on-exit cannot be unset, the hook stays so that it can still close the pane.
new_case; run_real 1 FAKE_TMUX_FAIL_ON='set-option -u'
expect "hook: option unset fails, the hook is left in place" tmux_not_logged 'set-hook -u -p'

# If the hook cannot be set, remain-on-exit is taken back at once, and nothing is left to unset.
new_case; run_real 1 FAKE_TMUX_FAIL_ON='set-hook -p'
expect "hook: set-hook fails, remain-on-exit is unset again" tmux_logged 'set-option -u -p -t %99 remain-on-exit'
expect "hook: set-hook fails, claude still starts" claude_started

# --- scripts/ccorch-pane-died.sh, as the hook runs it ---

PANE_DIED="${HERE}/../scripts/ccorch-pane-died.sh"
# pane_died <copy_result> <depth> — run on ${WORK_DIR}/p.md
pane_died() { bash "$PANE_DIED" "${WORK_DIR}/p.md" "$WORK_DIR" "$1" "$2" < /dev/null; }

new_case; pane_died 1 1
expect "pane-died, no result: status: error" grep -qxF 'status: error' "${WORK_DIR}/p.md"
expect "pane-died, no result: one status line" test "$(grep -c '^status:' "${WORK_DIR}/p.md")" = 1
expect "pane-died, Main Brain: result.md is a copy" cmp -s "${WORK_DIR}/p.md" "${WORK_DIR}/result.md"
expect "pane-died: no temporary file left" no_files "${WORK_DIR}"/*.tmp

new_case; printf 'pane result\n' > "${WORK_DIR}/p.md"; pane_died 1 1
expect "pane-died, result present: untouched" file_is "${WORK_DIR}/p.md" 'pane result'
expect "pane-died, result present, Main Brain: copied to result.md" file_is "${WORK_DIR}/result.md" 'pane result'

# A result rewritten after the last Stop: an older result.md must not hide it.
new_case; printf 'earlier\n' > "${WORK_DIR}/result.md"; printf 'rewritten\n' > "${WORK_DIR}/p.md"; pane_died 1 1
expect "pane-died: an older, differing result.md is replaced" file_is "${WORK_DIR}/result.md" 'rewritten'

new_case; printf 'earlier\n' > "${WORK_DIR}/result.md"; printf 'rewritten\n' > "${WORK_DIR}/p.md"
FAKE_CP_FAIL=1 pane_died 1 1
expect "pane-died, copy fails: the older result.md is removed" test ! -e "${WORK_DIR}/result.md"

new_case; pane_died 0 2
expect "pane-died, child: status: error" grep -qxF 'status: error' "${WORK_DIR}/p.md"
expect "pane-died, child: no result.md" test ! -e "${WORK_DIR}/result.md"

new_case; : > "${WORK_DIR}/p.md"; CCORCH_PUBLISH_GRACE=0 pane_died 0 3
expect "pane-died, empty result file: replaced by the error" grep -qxF 'status: error' "${WORK_DIR}/p.md"

new_case; pane_died 0 '9
status: success'
expect "pane-died, odd depth: one status line" test "$(grep -c '^status:' "${WORK_DIR}/p.md")" = 1
expect "pane-died, odd depth: depth x" grep -qxF 'depth: x' "${WORK_DIR}/p.md"

echo
echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
