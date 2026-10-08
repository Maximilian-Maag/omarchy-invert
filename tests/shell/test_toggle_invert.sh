#!/bin/bash
# Shell tests for bin/omarchy-toggle-invert — plain bash, no bats.
#
# The CLI is run with a stub hyprctl on PATH and a temporary XDG_STATE_HOME, so
# the dispatched module call and the status readout are observable and the real
# compositor is never touched.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="$ROOT/bin/omarchy-toggle-invert"
ORIG_PATH="$PATH"

FAIL=0
pass() { printf 'ok: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAIL=1; }
assert_contains() { # haystack-file needle description
  if grep -qF -- "$2" "$1" 2>/dev/null; then pass "$3"; else fail "$3 (missing '$2')"; fi
}
assert_not_contains() {
  if grep -qF -- "$2" "$1" 2>/dev/null; then fail "$3 (unexpected '$2')"; else pass "$3"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HOME_FAKE="$TMP/home"
STATE="$TMP/state"
BIN="$TMP/bin"
LOG="$TMP/hyprctl.log"
mkdir -p "$HOME_FAKE" "$BIN"
printf '#!/bin/bash\necho "$*" >> "$HYPRCTL_LOG"\nexit 0\n' > "$BIN/hyprctl"
chmod 755 "$BIN/hyprctl"

run_cli() { # args...
  HOME="$HOME_FAKE" XDG_STATE_HOME="$STATE" PATH="$BIN:$ORIG_PATH" HYPRCTL_LOG="$LOG" \
    bash "$CLI" "$@"
}
reset() { rm -rf "$STATE" "$LOG"; }
calls() { cat "$LOG" 2>/dev/null; }
write_status() { mkdir -p "$STATE/omarchy"; printf '%s' "$1" > "$STATE/omarchy/invert.status"; }

# ── dispatch for every meaningful mode/action ─────────────────────────────
while IFS='|' read -r args expected; do
  reset
  # shellcheck disable=SC2086
  run_cli $args
  if grep -qF "require('Maximilian-Maag.invert').$expected" "$LOG" 2>/dev/null; then
    pass "dispatch: $args -> $expected"
  else
    fail "dispatch: $args -> $expected (got '$(calls)')"
  fi
done <<'CASES'
desktop on|set('desktop', true)
desktop off|set('desktop', false)
desktop toggle|toggle('desktop')
window on|set('window', true)
window off|set('window', false)
window toggle|toggle('window')
window|toggle('window')
CASES

# ── validation ────────────────────────────────────────────────────────────
reset
ERR="$TMP/stderr"
run_cli monitor on 2>"$ERR"; rc=$?
if (( rc == 1 )); then pass "an invalid mode exits 1"; else fail "an invalid mode must exit 1 (got $rc)"; fi
assert_contains "$ERR" "Usage:" "an invalid mode prints usage to stderr"
assert_not_contains "$LOG" "hyprctl" "an invalid mode never dispatches"

reset
run_cli desktop blink 2>"$ERR"; rc=$?
if (( rc == 1 )); then pass "an invalid action exits 1"; else fail "an invalid action must exit 1 (got $rc)"; fi
assert_contains "$ERR" "Usage:" "an invalid action prints usage to stderr"
assert_not_contains "$LOG" "hyprctl" "an invalid action never dispatches"

# ── status readout ────────────────────────────────────────────────────────
reset
out="$(run_cli desktop --status)"
if [[ $out == '{"mode":"desktop","enabled":false}' ]]; then
  pass "no status file reports disabled"
else
  fail "no status file reports disabled (got '$out')"
fi
assert_not_contains "$LOG" "hyprctl" "reading status never dispatches"

reset
write_status 'desktop=true
window=false
'
out="$(run_cli desktop --status)"
if [[ $out == '{"mode":"desktop","enabled":true}' ]]; then
  pass "a true line reports enabled"
else
  fail "a true line reports enabled (got '$out')"
fi

reset
write_status 'desktop=false
window=true
'
out="$(run_cli desktop --status)"
if [[ $out == '{"mode":"desktop","enabled":false}' ]]; then
  pass "status is per-mode (window=true does not enable desktop)"
else
  fail "status is per-mode (got '$out')"
fi

# ── state directory ───────────────────────────────────────────────────────
reset
run_cli desktop --status >/dev/null
if [[ ! -d $STATE/omarchy ]]; then pass "status does not create the state dir"; else fail "status must not create the state dir"; fi

reset
run_cli desktop on >/dev/null
if [[ -d $STATE/omarchy ]]; then pass "a set action creates the state dir"; else fail "a set action must create the state dir"; fi

exit "$FAIL"