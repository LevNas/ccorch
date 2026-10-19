#!/bin/bash
# test_job.sh — tests for scripts/ccorch-job.sh (the job launcher) and scripts/ccorch-wait.sh.
# Plain bash; tmux is faked. The real tmux launch (no shell between tmux and the wrapper) is
# checked live, not here.
#
# Usage: bash tests/test_job.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
JOB="${HERE}/../scripts/ccorch-job.sh"
WAIT="${HERE}/../scripts/ccorch-wait.sh"
WRAPPER_ABS="$(cd "${HERE}/../scripts" && pwd)/ccorch-wrapper.sh"

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "${ROOT}/bin" "${ROOT}/tmp"

# The fake tmux writes each call's arguments, one per line, to $FAKE_TMUX_DIR/call-<n>.
#   new-window: prints %55 (fails when FAKE_NEW_WINDOW_FAIL is set)
#   wait-for:   exits $FAKE_WAIT_RC (default 0); writes result.md first when FAKE_WAIT_WRITES is set
#   list-panes: prints $FAKE_LIVE
cat > "${ROOT}/bin/tmux" <<'EOF'
#!/usr/bin/env bash
n=$(ls "$FAKE_TMUX_DIR" | wc -l)
printf '%s\n' "$@" > "$FAKE_TMUX_DIR/call-$n"
case "$1" in
  -V) echo "${FAKE_TMUX_VERSION:-tmux 3.7b}" ;;
  new-window) [ -n "${FAKE_NEW_WINDOW_FAIL:-}" ] && exit 1; echo %55 ;;
  wait-for)
    [ -n "${FAKE_WAIT_WRITES:-}" ] && echo "status: success" > "$FAKE_WAIT_WRITES"
    exit "${FAKE_WAIT_RC:-0}" ;;
  list-panes) printf '%s\n' ${FAKE_LIVE:-} ;;
esac
exit 0
EOF
chmod +x "${ROOT}/bin/tmux"
export PATH="${ROOT}/bin:${PATH}"
export TMPDIR="${ROOT}/tmp"

PASS=0
FAIL=0
expect()     { local d="$1"; shift; if "$@"; then PASS=$((PASS + 1)); echo "PASS: $d"; else FAIL=$((FAIL + 1)); echo "FAIL: $d"; fi; }
expect_not() { local d="$1"; shift; if "$@"; then FAIL=$((FAIL + 1)); echo "FAIL: $d"; else PASS=$((PASS + 1)); echo "PASS: $d"; fi; }

CASE=0
new_case() {
  CASE=$((CASE + 1))
  export FAKE_TMUX_DIR="${ROOT}/case${CASE}/tmux"
  mkdir -p "$FAKE_TMUX_DIR"
  REPO="${ROOT}/case${CASE}/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  TASK="${ROOT}/case${CASE}/task.md"
  printf 'Cover note\nit'\''s "quoted" $HOME\n' > "$TASK"
  unset FAKE_NEW_WINDOW_FAIL FAKE_WAIT_RC FAKE_WAIT_WRITES FAKE_LIVE CCORCH_MAX_PANES FAKE_TMUX_VERSION
}
run_job() { RC=0; bash "$JOB" "$@" > "${ROOT}/out" 2> "${ROOT}/err" || RC=$?; OUT=$(cat "${ROOT}/out"); ERR=$(cat "${ROOT}/err"); }
# new_window_args — the logged arguments of the new-window call
new_window_args() { grep -lx 'new-window' "$FAKE_TMUX_DIR"/call-* | head -1 | xargs cat; }
nw_has() { new_window_args | grep -qxF -- "$1"; }
# nw_pair <a> <b> — <b> follows <a> in the new-window arguments
nw_pair() { new_window_args | awk -v a="$1" -v b="$2" 'prev==a && $0==b {f=1} {prev=$0} END{exit !f}'; }
out_value() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p"; }

# --- Launch ---

new_case; run_job "$REPO" job-1 "$TASK" 120
expect "job: exit 0" test "$RC" -eq 0
WD=$(out_value work_dir)
expect "job: prints work_dir as TMPDIR/ccorch-job.XXXXXX" test "${WD#"${TMPDIR}/ccorch-job."}" != "$WD"
expect "job: prints a plain channel" bash -c '[[ "$1" =~ ^CCORCH_DONE_[A-Za-z0-9_]+$ ]]' _ "$(out_value channel)"
expect "job: prints the pane id" test "$(out_value pane)" = %55
expect "job: work dir exists" test -d "$WD"
expect "job: work dir is mode 700" test "$(stat -c %a "$WD")" = 700
expect "job: task copy is mode 600" test "$(stat -c %a "${WD}/job-task.md")" = 600
expect "job: fixed window name, no caller value" nw_pair -n ccorch-job
expect "job: task kept in the work dir, unchanged" cmp -s "$TASK" "${WD}/job-task.md"
expect "job: window starts in the repository" nw_pair -c "$(cd "$REPO" && pwd -P)"
expect "job: detached" nw_has -d
expect "job: CCORCH_MODE=job" nw_pair -e CCORCH_MODE=job
expect "job: CCORCH_WORKTREE" nw_pair -e CCORCH_WORKTREE=job-1
expect "job: CCORCH_DEPTH=1" nw_pair -e CCORCH_DEPTH=1
expect "job: CCORCH_PROJECT_DIR is the repository" nw_pair -e "CCORCH_PROJECT_DIR=$(cd "$REPO" && pwd -P)"
expect "job: CCORCH_WORK_DIR" nw_pair -e "CCORCH_WORK_DIR=${WD}"
expect "job: CCORCH_PARENT_CHANNEL is the printed channel" nw_pair -e "CCORCH_PARENT_CHANNEL=$(out_value channel)"
expect "job: CCORCH_TIMEOUT from the argument" nw_pair -e CCORCH_TIMEOUT=120
expect_not "job: CCORCH_MAX_PANES not passed when unset" bash -c 'grep -q "^CCORCH_MAX_PANES=" "$@"' _ "$FAKE_TMUX_DIR"/call-*
expect "job: command after --, run by bash -c without a shell string" nw_pair -- bash
expect "job: the shim execs the wrapper with the task file's text" \
  nw_has 'exec bash "$0" "$(cat "$1")"'
expect "job: wrapper path follows the shim" nw_pair 'exec bash "$0" "$(cat "$1")"' "$WRAPPER_ABS"
expect "job: task file follows the wrapper" nw_pair "$WRAPPER_ABS" "${WD}/job-task.md"

new_case; run_job "$REPO" job-1 "$TASK"
expect "job: default timeout 3600" nw_pair -e CCORCH_TIMEOUT=3600

new_case; CCORCH_MAX_PANES=3 run_job "$REPO" job-1 "$TASK"
expect "job: CCORCH_MAX_PANES passed on" nw_pair -e CCORCH_MAX_PANES=3

# The shim runs the wrapper with the task text as one argument (here with a stand-in wrapper).
new_case
printf '#!/bin/bash\nprintf "%%s" "$1" > "$OUT_ARG"\n' > "${ROOT}/stand-in.sh"
OUT_ARG="${ROOT}/case${CASE}/arg" bash -c 'exec bash "$0" "$(cat "$1")"' "${ROOT}/stand-in.sh" "$TASK"
expect "shim: the task text arrives as one argument" test "$(cat "${ROOT}/case${CASE}/arg")" = "$(cat "$TASK")"

# --- Refusals (exit 2, nothing launched) ---

no_launch() { ! grep -qlx 'new-window' "$FAKE_TMUX_DIR"/call-* 2>/dev/null; }

new_case; run_job "$REPO" job-1
expect "too few arguments: exit 2" test "$RC" -eq 2
new_case; run_job "${ROOT}/nowhere" job-1 "$TASK"
expect "missing repository: exit 2" test "$RC" -eq 2
new_case; mkdir -p "${ROOT}/case${CASE}/plain"; run_job "${ROOT}/case${CASE}/plain" job-1 "$TASK"
expect "not a git repository: exit 2" test "$RC" -eq 2
new_case; mkdir -p "$REPO/sub"; run_job "$REPO/sub" job-1 "$TASK"
expect "a subdirectory, not the top: exit 2" test "$RC" -eq 2
expect "a subdirectory: names the top" bash -c 'printf "%s" "$1" | grep -qF "top directory"' _ "$ERR"
new_case; : > "$TASK"; run_job "$REPO" job-1 "$TASK"
expect "empty task file: exit 2" test "$RC" -eq 2
for bad in 0 -5 abc 1234567; do
  new_case; run_job "$REPO" job-1 "$TASK" "$bad"
  expect "timeout '$bad': exit 2" test "$RC" -eq 2
  expect "timeout '$bad': nothing launched" no_launch
done
new_case; FAKE_NEW_WINDOW_FAIL=1 run_job "$REPO" job-1 "$TASK"
expect "tmux new-window fails: exit 2" test "$RC" -eq 2
for bad in '-w' '.hidden' 'a..b' 'a/b' '#(id)' "$(printf 'a%.0s' {1..65})"; do
  new_case; run_job "$REPO" "$bad" "$TASK"
  expect "worktree name '${bad:0:20}': exit 2" test "$RC" -eq 2
  expect "worktree name '${bad:0:20}': nothing launched" no_launch
done
new_case; mkdir -p "$REPO/.claude/worktrees/job-1"; run_job "$REPO" job-1 "$TASK"
expect "existing worktree directory: exit 2" test "$RC" -eq 2
expect "existing worktree directory: nothing launched" no_launch
new_case; HASH_REPO="${ROOT}/case${CASE}/re#po"; mkdir -p "$HASH_REPO"; git -C "$HASH_REPO" init -q
run_job "$HASH_REPO" job-1 "$TASK"
expect "repository path with '#': exit 2" test "$RC" -eq 2
expect "repository path with '#': nothing launched" no_launch
new_case; head -c 100001 /dev/zero | tr '\0' a > "$TASK"; run_job "$REPO" job-1 "$TASK"
expect "task over 100000 bytes: exit 2" test "$RC" -eq 2
new_case; head -c 100000 /dev/zero | tr '\0' a > "$TASK"; run_job "$REPO" job-1 "$TASK"
expect "task of 100000 bytes: exit 0" test "$RC" -eq 0
new_case; FAKE_TMUX_VERSION='tmux 2.9a' run_job "$REPO" job-1 "$TASK"
expect "tmux 2.9a: exit 2" test "$RC" -eq 2
expect "tmux 2.9a: nothing launched" no_launch
new_case; FAKE_TMUX_VERSION='tmux next-3.8' run_job "$REPO" job-1 "$TASK"
expect "tmux next-3.8: exit 0" test "$RC" -eq 0
new_case; FAKE_TMUX_VERSION='weird' run_job "$REPO" job-1 "$TASK"
expect "unreadable tmux version: exit 2" test "$RC" -eq 2

# --- Wait ---

run_wait() { RC=0; bash "$WAIT" "$@" > "${ROOT}/out" 2> "${ROOT}/err" || RC=$?; OUT=$(cat "${ROOT}/out"); ERR=$(cat "${ROOT}/err"); }

new_case; W="${ROOT}/case${CASE}/w"; mkdir -p "$W"; echo "status: success" > "$W/result.md"
run_wait "$W" CH
expect "wait: result already there: exit 0" test "$RC" -eq 0
expect "wait: prints the result path" test "$OUT" = "result=${W}/result.md"

new_case; W="${ROOT}/case${CASE}/w"; mkdir -p "$W"
FAKE_WAIT_WRITES="$W/result.md" run_wait "$W" CH
expect "wait: result written before the signal: exit 0" test "$RC" -eq 0

new_case; W="${ROOT}/case${CASE}/w"; mkdir -p "$W"
FAKE_WAIT_RC=1 run_wait "$W" CH
expect "wait: wait-for fails: exit 1" test "$RC" -eq 1
expect "wait: wait-for fails: says so" bash -c 'printf "%s" "$1" | grep -qF "tmux wait-for failed"' _ "$ERR"

new_case; W="${ROOT}/case${CASE}/w"; mkdir -p "$W"
run_wait "$W" CH
expect "wait: signal, no result, no pane recorded: exit 1" test "$RC" -eq 1
expect "wait: says no pane is alive" bash -c 'printf "%s" "$1" | grep -qF "no depth-1 pane is alive"' _ "$ERR"

new_case; run_wait "${ROOT}/missing" CH
expect "wait: missing work dir: exit 2" test "$RC" -eq 2
new_case; W="${ROOT}/case${CASE}/w"; mkdir -p "$W"; run_wait "$W" ''
expect "wait: empty channel: exit 2" test "$RC" -eq 2
new_case; W="${ROOT}/case${CASE}/w"; mkdir -p "$W"; run_wait "$W" '-S'
expect "wait: channel starting with '-': exit 2" test "$RC" -eq 2
expect "wait: channel starting with '-': no tmux call" bash -c '! ls "$1" | grep -q .' _ "$FAKE_TMUX_DIR"

# --- The skill's cover note keeps its five sections ---

SKILL="${HERE}/../skills/job/SKILL.md"
for section in '## Where you work' "## The repository's rules" '## Working files' '## What to return' '## When you are stopped'; do
  expect "skill: cover note has '${section}'" grep -qxF -- "$section" "$SKILL"
done
expect "skill: names the launcher" grep -qF 'ccorch-job.sh' "$SKILL"
expect "skill: names the wait script" grep -qF 'ccorch-wait.sh' "$SKILL"

echo
echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
