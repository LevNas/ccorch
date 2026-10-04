#!/usr/bin/env bash
# test_tmux_hook.sh — the wrapper's pane-died hook on a real tmux server.
#
# Runs a private tmux server (tmux -S <temp socket>), so the user's tmux is never touched. claude is
# a fake that sleeps. The pane is started the way a parent starts a child, with the command
# string "ENV=... bash ccorch-wrapper.sh '<task>'", so that the shell tmux starts for it has
# to exec the wrapper for the hook to see the wrapper's death. Skipped when tmux is missing.
#
#   bash tests/test_tmux_hook.sh

set -u

if ! command -v tmux >/dev/null 2>&1; then
  echo "SKIP: tmux not found"
  exit 0
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$(cd "${HERE}/../scripts" && pwd)/ccorch-wrapper.sh"
ROOT="$(mktemp -d)"
# The socket lives in ROOT, so nothing is left in the user's tmux socket directory.
TM=(tmux -S "${ROOT}/tmux.sock" -f /dev/null)
# A unique sleep length marks the fake claude's processes, so the test can find leftovers.
MARK="4321.$$"

cleanup() {
  "${TM[@]}" kill-server 2>/dev/null
  pkill -f "sleep ${MARK}" 2>/dev/null
  rm -rf "$ROOT"
}
trap cleanup EXIT

mkdir -p "${ROOT}/bin" "${ROOT}/project"
cat > "${ROOT}/bin/claude" <<EOF
#!/usr/bin/env bash
: > "\${CCORCH_RESULT_FILE}.started"
if [ -n "\${FAKE_CLAUDE_WRITE:-}" ]; then
  printf '%s\n' "\$FAKE_CLAUDE_WRITE" > "\$CCORCH_RESULT_FILE"
  exit 0
fi
exec sleep ${MARK}
EOF
chmod +x "${ROOT}/bin/claude"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
expect() { local d="$1"; shift; if "$@"; then ok "$d"; else fail "$d"; fi }

# The server's environment is what every pane, and every hook's run-shell, inherits.
env -u TMUX PATH="${ROOT}/bin:${PATH}" "${TM[@]}" new-session -d -s base -x 120 -y 30 "sleep 600"

# start_pane <name> [VAR=value ...] — a Main Brain pane in window <name>; sets W (work dir),
# CH (channel) and PANE (the new pane's id).
start_pane() {
  local name="$1"; shift
  W="${ROOT}/work-${name}"
  CH="ccorch_test_${name}_$$"
  mkdir -p "$W"
  # PATH goes in the command itself: tmux runs it with the user's shell, whose startup files
  # may rebuild PATH and drop the fake bin (the real claude would then start).
  PANE=$("${TM[@]}" new-window -d -P -F '#{pane_id}' -t base: -n "$name" \
    "PATH=$(printf '%q' "${ROOT}/bin:${PATH}") $* CCORCH_DEPTH=1 CCORCH_SESSION_ID=${name} CCORCH_PARENT_CHANNEL=${CH} CCORCH_WORK_DIR=${W} CCORCH_PROJECT_DIR=${ROOT}/project CCORCH_TIMEOUT=120 CCORCH_MAX_PANES=8 bash ${WRAPPER} 'test task'")
}
# wait_started — until the fake claude has started (the hook is armed by then)
wait_started() {
  local i
  for i in $(seq 1 50); do
    ls "$W"/depth1-*.md.started >/dev/null 2>&1 && return 0
    sleep 0.2
  done
  return 1
}
pane_listed() { "${TM[@]}" list-panes -a -F '#{pane_id}' | grep -qxF -- "$PANE"; }
result_file() { ls "$W"/depth1-*.md 2>/dev/null | head -1; }

# --- SIGKILL of the wrapper alone: tmux writes the result, signals, closes the pane ---
# Under each shell tmux may start the pane with: the hook sees the wrapper's death only if
# that shell execs the wrapper (the pane's program is then the wrapper itself).

kill_case() { # kill_case <label> <shell>
  local label="$1" shell="$2" PID
  "${TM[@]}" set-option -g default-shell "$shell"
  start_pane "killed-${label}"
  if ! wait_started; then
    # Stop here rather than kill something else: the fake claude did not start.
    fail "SIGKILL (${label}): the fake claude started (aborting)"
    echo; echo "${PASS} passed, ${FAIL} failed"; exit 1
  fi
  ok "SIGKILL (${label}): the fake claude started"
  PID=$("${TM[@]}" display-message -p -t "$PANE" '#{pane_pid}')
  if ! ps -o args= -p "$PID" | grep -qF ccorch-wrapper.sh; then
    fail "SIGKILL (${label}): the pane's program is the wrapper (${shell} did not exec it)"
    return
  fi
  ok "SIGKILL (${label}): the pane's program is the wrapper (${shell} exec'd it)"
  kill -9 "$PID"
  expect "SIGKILL (${label}): the parent channel is signalled" timeout 10 "${TM[@]}" wait-for "$CH"
  expect "SIGKILL (${label}): the result file says status: error" grep -qxF 'status: error' "$(result_file)"
  expect "SIGKILL (${label}): result.md holds it (Main Brain)" grep -qxF 'status: error' "${W}/result.md"
  sleep 0.5
  if pane_listed; then fail "SIGKILL (${label}): the pane is closed (still listed)"; else ok "SIGKILL (${label}): the pane is closed"; fi
  sleep 0.5
  if pgrep -f "sleep ${MARK}" >/dev/null; then fail "SIGKILL (${label}): the orphaned claude is gone"; else ok "SIGKILL (${label}): the orphaned claude is gone"; fi
}

USER_SHELL="${SHELL:-/bin/sh}"
kill_case user "$USER_SHELL"
if [ -x /bin/sh ] && [ "$(readlink -f /bin/sh)" != "$(readlink -f "$USER_SHELL")" ]; then
  kill_case sh /bin/sh
fi
"${TM[@]}" set-option -g default-shell "$USER_SHELL"

# --- Normal exit: one signal (the trap's), no hook, no dead pane left behind ---

start_pane normal FAKE_CLAUDE_WRITE=done
expect "normal: the parent channel is signalled" timeout 15 "${TM[@]}" wait-for "$CH"
expect "normal: the result is the pane's" grep -qxF 'done' "${W}/result.md"
if timeout 3 "${TM[@]}" wait-for "$CH"; then fail "normal: no second signal (the hook did not run)"; else ok "normal: no second signal (the hook did not run)"; fi
if pane_listed; then fail "normal: the pane is closed, not left dead"; else ok "normal: the pane is closed, not left dead"; fi

echo
echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
