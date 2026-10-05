#!/bin/bash
# omarchy-invert install script
# Wires the plugin into the live Omarchy/Hyprland config.
# Safe to re-run — all steps are idempotent.

set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYPR_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hypr"
HYPR_MAIN="$HYPR_CONFIG_DIR/hyprland.lua"
BIN_DIR="/usr/local/bin"
LUA_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/Maximilian-Maag"

echo "omarchy-invert: installing from $PLUGIN_DIR"

# ── 1. Place Lua module where require('Maximilian-Maag.invert') finds it ──────
# Hyprland's Lua path includes ~/.config/?.lua, so the module must live at
# ~/.config/Maximilian-Maag/invert.lua
mkdir -p "$LUA_DIR"
ln -sf "$PLUGIN_DIR/hypr/invert.lua" "$LUA_DIR/invert.lua"
echo "  Linked Lua module -> $LUA_DIR/invert.lua"

# ── 2. Install CLI binary onto PATH ───────────────────────────────────────────
DEST_BIN="$BIN_DIR/omarchy-toggle-invert"
SRC_BIN="$PLUGIN_DIR/bin/omarchy-toggle-invert"
# Skip if already a symlink pointing to our source
if [[ -L "$DEST_BIN" ]] && [[ "$(readlink -f "$DEST_BIN")" == "$(readlink -f "$SRC_BIN")" ]]; then
  echo "  Binary already linked."
else
  _install_bin() {
    cp "$SRC_BIN" "$DEST_BIN"
    chmod 755 "$DEST_BIN"
  }
  if [[ $EUID -eq 0 ]]; then
    _install_bin
  elif command -v sudo >/dev/null 2>&1; then
    sudo bash -c "cp '$SRC_BIN' '$DEST_BIN' && chmod 755 '$DEST_BIN'"
  else
    pkexec bash -c "cp '$SRC_BIN' '$DEST_BIN' && chmod 755 '$DEST_BIN'"
  fi
  echo "  Installed binary -> $DEST_BIN"
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
  printf '\n-- omarchy-invert plugin\nrequire("Maximilian-Maag.invert")\n' >> "$HYPR_MAIN"
  echo "  Added require to $HYPR_MAIN"
fi

# ── 4. Register keybindings in ~/.config/hypr/bindings.lua ───────────────────
BINDINGS="$HYPR_CONFIG_DIR/bindings.lua"
if [[ -f "$BINDINGS" ]] && ! grep -q 'omarchy-toggle-invert' "$BINDINGS"; then
  cat >> "$BINDINGS" << 'LUA'

-- omarchy-invert plugin
o.bind("SUPER + CTRL + U",       "Toggle focused window color inversion", "omarchy-toggle-invert window")
o.bind("SUPER + CTRL + ALT + U", "Toggle desktop color inversion",        "omarchy-toggle-invert desktop")
LUA
  echo "  Added keybindings to $BINDINGS"
elif grep -q 'omarchy-toggle-invert' "${BINDINGS:-/dev/null}" 2>/dev/null; then
  echo "  Keybindings already present."
else
  echo "  No bindings.lua found — add these manually:"
  echo '    o.bind("SUPER + CTRL + U",       "Toggle focused window color inversion", "omarchy-toggle-invert window")'
  echo '    o.bind("SUPER + CTRL + ALT + U", "Toggle desktop color inversion",        "omarchy-toggle-invert desktop")'
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
echo "  Super + Ctrl + U        — invert focused window (toggle per-window)"
echo "  Super + Ctrl + Alt + U  — invert whole desktop"
