#!/bin/bash
# omarchy-invert install script
# Wires the plugin into the live Omarchy/Hyprland config.
# Safe to re-run — all steps are idempotent.
#
#   ./install.sh                     link the module and the CLI, wire the config
#   ./install.sh --uninstall         remove exactly what this script installed
#
# `--uninstall` reverses each step and nothing else: the module symlink and the
# CLI are removed only when they point into (or match) this checkout, and the
# require line and the keybinding block are taken back out of the user's config
# by exact content, so a real file or a foreign link is never touched.

set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYPR_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hypr"
HYPR_MAIN="$HYPR_CONFIG_DIR/hyprland.lua"
BINDINGS="$HYPR_CONFIG_DIR/bindings.lua"
REQUIRE_LINE='require("Maximilian-Maag.invert")'
MARKER='-- omarchy-invert plugin'
# Overridable so the shell tests can install into a throwaway bin dir.
BIN_DIR="${OMARCHY_INVERT_BIN:-/usr/local/bin}"
LUA_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/Maximilian-Maag"
DEST_BIN="$BIN_DIR/omarchy-toggle-invert"
SRC_BIN="$PLUGIN_DIR/bin/omarchy-toggle-invert"
DEST_LUA="$LUA_DIR/invert.lua"
SRC_LUA="$PLUGIN_DIR/hypr/invert.lua"

say() { printf '  %s\n' "$1"; }
warn() { printf 'WARNING: %s\n' "$1" >&2; }

# unlink_ours <path> <source it must point at> — remove a symlink only when it
# resolves to the file this checkout ships; anything else is left alone.
unlink_ours() {
  local dest="$1" source="$2"
  if [[ -L $dest ]] && [[ "$(readlink -f "$dest")" == "$(readlink -f "$source")" ]]; then
    rm -f "$dest"
    say "removed $dest"
  elif [[ -e $dest ]]; then
    warn "$dest is not a link into this checkout — left alone."
  fi
}

# remove_bin — the CLI lives in a system dir, so removal needs the same
# privilege the install used (root, or sudo when it is available).
remove_bin() {
  if (( EUID == 0 )); then
    rm -f "$DEST_BIN"
  elif command -v sudo >/dev/null 2>&1; then
    sudo rm -f "$DEST_BIN"
  else
    warn "no sudo — remove $DEST_BIN by hand."
    return 0
  fi
  say "removed $DEST_BIN"
}

# drop_require_line <file> — take the appended
#   <blank>
#   -- omarchy-invert plugin
#   require("Maximilian-Maag.invert")
# block back out of the user's Hyprland config. The file is rebuilt line by
# line rather than filtered in place, so the user's own lines (and the trailing
# newline) are preserved byte for byte.
drop_require_line() {
  local file="$1"
  [[ -f $file ]] || return 0
  if ! grep -qF "$REQUIRE_LINE" "$file"; then
    say "no require line to remove in $file"
    return 0
  fi
  local tmp; tmp="$(mktemp)"
  local lines=() out=() line
  mapfile -t lines < "$file"
  for line in "${lines[@]}"; do
    if [[ $line == "$REQUIRE_LINE" ]]; then
      # The line was written as a block, so the marker comment and the blank
      # line before it go with it; leaving them behind would stack another
      # marker on the file at every install/uninstall cycle.
      if (( ${#out[@]} )) && [[ ${out[-1]} == "$MARKER" ]]; then
        unset 'out[-1]'
        if (( ${#out[@]} )) && [[ -z ${out[-1]} ]]; then
          unset 'out[-1]'
        fi
      fi
      continue
    fi
    out+=("$line")
  done
  for line in ${out[@]+"${out[@]}"}; do
    printf '%s\n' "$line"
  done > "$tmp"
  mv "$tmp" "$file"
  say "removed the require line from $file"
}

# drop_bindings_block <file> — take the appended keybinding block back out.
# The bind lines and their marker comment (with the blank line above it) go;
# every other line is kept verbatim.
drop_bindings_block() {
  local file="$1"
  [[ -f $file ]] || return 0
  if ! grep -q 'omarchy-toggle-invert' "$file"; then
    say "no keybindings to remove in $file"
    return 0
  fi
  local tmp; tmp="$(mktemp)"
  local lines=() out=() line
  mapfile -t lines < "$file"
  for line in "${lines[@]}"; do
    if [[ $line == *omarchy-toggle-invert* ]]; then
      if (( ${#out[@]} )) && [[ ${out[-1]} == "$MARKER" ]]; then
        unset 'out[-1]'
        if (( ${#out[@]} )) && [[ -z ${out[-1]} ]]; then
          unset 'out[-1]'
        fi
      fi
      continue
    fi
    out+=("$line")
  done
  for line in ${out[@]+"${out[@]}"}; do
    printf '%s\n' "$line"
  done > "$tmp"
  mv "$tmp" "$file"
  say "removed the keybindings from $file"
}

uninstall() {
  echo "omarchy-invert: uninstalling"
  unlink_ours "$DEST_LUA" "$SRC_LUA"

  # The CLI is a symlink into this checkout; a stale copy from an older install
  # (before this script linked instead of copying) is removed too, but only when
  # it is byte-identical to what this checkout ships.
  if [[ -L $DEST_BIN ]]; then
    if [[ "$(readlink -f "$DEST_BIN")" == "$(readlink -f "$SRC_BIN")" ]]; then
      remove_bin
    else
      warn "$DEST_BIN is a link, but not into this checkout — left alone."
    fi
  elif [[ -f $DEST_BIN ]] && cmp -s "$SRC_BIN" "$DEST_BIN"; then
    remove_bin
  elif [[ -e $DEST_BIN ]]; then
    warn "$DEST_BIN is not ours — left alone."
  fi

  drop_require_line "$HYPR_MAIN"
  drop_bindings_block "$BINDINGS"

  echo ""
  echo "Done. Reload Hyprland:  hyprctl reload"
}

if [[ ${1:-} == --uninstall ]]; then
  uninstall
  exit 0
fi

echo "omarchy-invert: installing from $PLUGIN_DIR"

# ── 1. Place Lua module where require('Maximilian-Maag.invert') finds it ──────
# Hyprland's Lua path includes ~/.config/?.lua, so the module must live at
# ~/.config/Maximilian-Maag/invert.lua
mkdir -p "$LUA_DIR"
ln -sf "$SRC_LUA" "$DEST_LUA"
echo "  Linked Lua module -> $DEST_LUA"

# ── 2. Install CLI binary onto PATH ───────────────────────────────────────────
# Symlink, don't copy: a copy goes stale the moment this repo changes, so a
# `git pull` never reached the installed binary. A symlink keeps it current, and
# the "already linked" guard below keeps re-runs idempotent.
chmod +x "$SRC_BIN"
if [[ -L "$DEST_BIN" ]] && [[ "$(readlink -f "$DEST_BIN")" == "$(readlink -f "$SRC_BIN")" ]]; then
  echo "  Binary already linked."
elif (( EUID == 0 )); then
  ln -sf "$SRC_BIN" "$DEST_BIN" && echo "  Installed binary -> $DEST_BIN"
elif command -v sudo >/dev/null 2>&1; then
  sudo ln -sf "$SRC_BIN" "$DEST_BIN" && echo "  Installed binary -> $DEST_BIN"
else
  echo "  WARNING: no sudo — add $SRC_BIN to PATH manually."
fi

# ── 3. Wire into Hyprland config ──────────────────────────────────────────────
# Add require("Maximilian-Maag.invert") to hyprland.lua if not already present.
if [[ ! -f "$HYPR_MAIN" ]]; then
  echo "  WARNING: $HYPR_MAIN not found — skipping Hyprland wiring"
  echo "  Add this line manually to your hyprland.lua:"
  echo "    require(\"Maximilian-Maag.invert\")"
elif grep -q 'Maximilian-Maag.invert' "$HYPR_MAIN"; then
  echo "  Hyprland config already loads the module."
else
  printf '\n%s\n%s\n' "$MARKER" "$REQUIRE_LINE" >> "$HYPR_MAIN"
  echo "  Added require to $HYPR_MAIN"
fi

# ── 4. Register keybindings in ~/.config/hypr/bindings.lua ───────────────────
if [[ -f "$BINDINGS" ]] && ! grep -q 'omarchy-toggle-invert' "$BINDINGS"; then
  cat >> "$BINDINGS" << LUA

$MARKER
o.bind("SUPER + CTRL + U",       "Cycle focused window: off / invert / high-contrast", "omarchy-toggle-invert window")
o.bind("SUPER + CTRL + ALT + U", "Cycle desktop: off / invert / high-contrast",        "omarchy-toggle-invert desktop")
LUA
  echo "  Added keybindings to $BINDINGS"
elif grep -q 'omarchy-toggle-invert' "${BINDINGS:-/dev/null}" 2>/dev/null; then
  echo "  Keybindings already present."
else
  echo "  No bindings.lua found — add these manually:"
  echo '    o.bind("SUPER + CTRL + U",       "Cycle focused window: off / invert / high-contrast", "omarchy-toggle-invert window")'
  echo '    o.bind("SUPER + CTRL + ALT + U", "Cycle desktop: off / invert / high-contrast",        "omarchy-toggle-invert desktop")'
fi

# ── 5. Reload Hyprland ────────────────────────────────────────────────────────
if command -v hyprctl >/dev/null 2>&1 && [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
  hyprctl reload >/dev/null 2>&1 && echo "  Hyprland reloaded." || echo "  Hyprland reload failed — reload manually."
else
  echo "  Run 'hyprctl reload' to activate."
fi

echo ""
echo "Done!"
echo ""
echo "Keybindings:"
echo "  Super + Ctrl + U        — cycle focused window: off / invert / high-contrast"
echo "  Super + Ctrl + Alt + U  — cycle desktop: off / invert / high-contrast"
