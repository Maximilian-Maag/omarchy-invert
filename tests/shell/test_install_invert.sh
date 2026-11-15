#!/bin/bash
# Shell tests for install.sh — run hermetically under a throwaway HOME/XDG.
#
# The installer LINKS the CLI onto PATH rather than copying it (issue #5): a copy
# goes stale the moment the repo changes, so a `git pull` never reached the
# installed binary. These tests install from a throwaway copy of the shipped files
# into a throwaway bin dir and assert the destination is a symlink into that
# checkout that tracks the source, and that install.sh still uses `ln -sf`.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="$ROOT/install.sh"
pass=0; fail=0
ok()  { echo "  ok: $*"; pass=$((pass+1)); }
bad() { echo "  FAIL: $*"; fail=$((fail+1)); }

# extract <sandbox-dir> — a throwaway copy of what the installer links, so a test
# never depends on (or edits) this repo's working tree.
extract() {
  local sbx="$1"
  mkdir -p "$sbx/bin" "$sbx/hypr"
  cp "$INSTALL" "$sbx/install.sh"
  cp "$ROOT/bin/omarchy-toggle-invert" "$sbx/bin/"
  cp "$ROOT/hypr/invert.lua" "$sbx/hypr/"
}

# 1. the script parses
if bash -n "$INSTALL"; then ok "install.sh parses"; else bad "install.sh has a syntax error"; fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# EUID is nonzero here, so the installer takes its `sudo` branch; a stub sudo that
# just runs its arguments keeps the test from ever prompting for a password.
STUB="$TMP/stub"; mkdir -p "$STUB"
printf '#!/bin/bash\nexec "$@"\n' > "$STUB/sudo"
chmod 755 "$STUB/sudo"

run_install() {  # <sandbox> <bindir> <fakehome>
  HOME="$3" XDG_CONFIG_HOME="$3/.config" OMARCHY_INVERT_BIN="$2" \
    PATH="$STUB:$PATH" bash "$1/install.sh"
}

# 2. install exits 0 and the CLI is a symlink into the source checkout
SBX="$TMP/repo"; extract "$SBX"
BIN="$TMP/bin"; mkdir -p "$BIN"
HOME_FAKE="$TMP/home"; mkdir -p "$HOME_FAKE"
DEST="$BIN/omarchy-toggle-invert"
SRC="$SBX/bin/omarchy-toggle-invert"

if run_install "$SBX" "$BIN" "$HOME_FAKE" >/dev/null 2>&1; then
  ok "install exits 0"
else
  bad "install exited non-zero"
fi
if [[ -L "$DEST" && "$(readlink -f "$DEST")" == "$(readlink -f "$SRC")" ]]; then
  ok "the CLI is symlinked onto PATH (not copied)"
else
  bad "the CLI is missing or not a symlink into the checkout"
fi

# 3. it TRACKS the checkout: an edit to the source shows through with no re-install.
#    A copy would go stale — exactly the bug this fix removes.
marker="durability-probe-$$"
printf '\n# %s\n' "$marker" >> "$SRC"
if grep -q "$marker" "$DEST"; then
  ok "the installed CLI tracks the source (no stale copy)"
else
  bad "the installed CLI went stale (the file was copied, not linked)"
fi

# 4. re-running is idempotent and leaves the link intact
if run_install "$SBX" "$BIN" "$HOME_FAKE" >/dev/null 2>&1 && [[ -L "$DEST" ]]; then
  ok "re-running the install is idempotent"
else
  bad "a second install broke the link"
fi

# 5. install.sh links the CLI with ln -sf — a regression to `cp` would reintroduce
#    the staleness this fix removes.
if grep -qF 'ln -sf "$SRC_BIN"' "$INSTALL"; then
  ok "install.sh installs the CLI with ln -sf"
else
  bad "install.sh must install the CLI with ln -sf (not a copy)"
fi

echo
if (( fail == 0 )); then echo "shell: all $pass passed"; exit 0; else echo "shell: $fail failed"; exit 1; fi
