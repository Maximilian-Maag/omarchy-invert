#!/bin/bash
# Round-trip test for install.sh --uninstall — run hermetically under a throwaway
# HOME/XDG, with a stub sudo so no password is ever asked for.
#
# The contract: uninstall removes EXACTLY what install added — the CLI symlink
# (only when it points into this checkout), the Lua module symlink, the require
# line and the keybinding block — and leaves the user's own config byte-for-byte
# as it was. A foreign file or link at any of those paths is left alone.
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

if bash -n "$INSTALL"; then ok "install.sh parses"; else bad "install.sh has a syntax error"; fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# EUID is nonzero here, so the installer takes its `sudo` branch; a stub sudo that
# just runs its arguments keeps the test from ever prompting for a password.
STUB="$TMP/stub"; mkdir -p "$STUB"
printf '#!/bin/bash\nexec "$@"\n' > "$STUB/sudo"
chmod 755 "$STUB/sudo"

SBX="$TMP/repo"; extract "$SBX"
BIN="$TMP/bin"; mkdir -p "$BIN"
HOME_FAKE="$TMP/home"
CONFIG="$HOME_FAKE/.config"
mkdir -p "$CONFIG/hypr"
HYPR="$CONFIG/hypr/hyprland.lua"
BIND="$CONFIG/hypr/bindings.lua"
LUA="$CONFIG/Maximilian-Maag/invert.lua"
DEST="$BIN/omarchy-toggle-invert"

# The user's own config, as it was before the install.
printf 'require("default.hypr.omarchy")\nlocal monitors = {}\n' > "$HYPR"
printf 'local o = require("hypr.bindings")\no.bind("SUPER + RETURN", "Terminal", "kitty")\n' > "$BIND"
hypr_before="$(sha256sum "$HYPR" | cut -d' ' -f1)"
bind_before="$(sha256sum "$BIND" | cut -d' ' -f1)"

run() {  # [args...]
  HOME="$HOME_FAKE" XDG_CONFIG_HOME="$CONFIG" OMARCHY_INVERT_BIN="$BIN" \
    PATH="$STUB:$PATH" bash "$SBX/install.sh" "$@"
}

# 1. install, then assert everything landed.
if run >/dev/null 2>&1; then ok "install exits 0"; else bad "install exited non-zero"; fi
[[ -L "$DEST" && "$(readlink -f "$DEST")" == "$(readlink -f "$SBX/bin/omarchy-toggle-invert")" ]] \
  && ok "the CLI is a symlink into the checkout" || bad "the CLI is missing or not our link"
[[ -L "$LUA" && "$(readlink -f "$LUA")" == "$(readlink -f "$SBX/hypr/invert.lua")" ]] \
  && ok "the Lua module is symlinked into place" || bad "the Lua module is missing or not our link"
grep -qF 'require("Maximilian-Maag.invert")' "$HYPR" && ok "the require line was added" || bad "no require line"
grep -qF 'omarchy-toggle-invert' "$BIND" && ok "the keybindings were added" || bad "no keybindings"

# 2. uninstall reverses the install.
if run --uninstall >/dev/null 2>&1; then ok "uninstall exits 0"; else bad "uninstall exited non-zero"; fi
[[ -e "$DEST" ]]   && bad "the CLI link was left behind" || ok "the CLI link is gone"
[[ -e "$LUA" ]]    && bad "the Lua link was left behind" || ok "the Lua link is gone"
grep -qF 'Maximilian-Maag.invert' "$HYPR" && bad "the require line was left behind" || ok "the require line is gone"
grep -qF 'omarchy-toggle-invert' "$BIND" && bad "the keybindings were left behind" || ok "the keybindings are gone"

# 3. the user's config is byte-for-byte as it was — no marker, no stray blank line.
[[ "$(sha256sum "$HYPR" | cut -d' ' -f1)" == "$hypr_before" ]] \
  && ok "hyprland.lua survived the round-trip byte-identical" || bad "hyprland.lua changed"
[[ "$(sha256sum "$BIND" | cut -d' ' -f1)" == "$bind_before" ]] \
  && ok "bindings.lua survived the round-trip byte-identical" || bad "bindings.lua changed"
grep -qF -- '-- omarchy-invert plugin' "$HYPR" && bad "a marker was left in hyprland.lua" || ok "no marker stacked in hyprland.lua"
grep -qF -- '-- omarchy-invert plugin' "$BIND" && bad "a marker was left in bindings.lua" || ok "no marker stacked in bindings.lua"

# 4. a second cycle does not drift either.
run >/dev/null 2>&1; run --uninstall >/dev/null 2>&1
[[ "$(sha256sum "$HYPR" | cut -d' ' -f1)" == "$hypr_before" \
   && "$(sha256sum "$BIND" | cut -d' ' -f1)" == "$bind_before" ]] \
  && ok "a second install/uninstall cycle is still byte-identical" || bad "the config drifted on a second cycle"

# 5. a foreign link at the CLI name is left alone, and uninstall still succeeds.
run >/dev/null 2>&1
rm -f "$DEST"; ln -sf /bin/true "$DEST"
out="$(run --uninstall 2>&1)"; code=$?
(( code == 0 )) && ok "uninstall exits 0 with a foreign CLI link present" || bad "uninstall failed on a foreign link"
[[ -L "$DEST" ]] && ok "a foreign CLI link is left alone" || bad "a foreign CLI link was removed"
grep -qF 'left alone' <<< "$out" && ok "and it says why" || bad "no reason given for the foreign link"

# 6. a foreign regular file at the Lua path is left alone.
rm -f "$DEST"
printf 'not ours\n' > "$LUA"
run --uninstall >/dev/null 2>&1
[[ -f "$LUA" && ! -L "$LUA" ]] && ok "a foreign Lua file is left alone" || bad "a foreign Lua file was removed"
rm -f "$LUA"

# 7. uninstalling nothing is not an error.
run --uninstall >/dev/null 2>&1 && ok "uninstalling nothing exits 0" || bad "uninstalling nothing failed"

echo
if (( fail == 0 )); then echo "shell: all $pass passed"; exit 0; else echo "shell: $fail failed"; exit 1; fi
