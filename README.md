# omarchy-invert

Color inversion plugin for [Omarchy](https://omarchy.org/) — flip the colors of
the focused window or the whole desktop without leaving the keyboard.

| Hotkey | Action |
|--------|--------|
| `Super + Ctrl + U` | Toggle focused window inversion |
| `Super + Ctrl + Alt + U` | Toggle whole-desktop inversion |

Both modes are also available as CLI commands:

```bash
omarchy toggle invert window          # toggle window inversion
omarchy toggle invert desktop         # toggle desktop inversion
omarchy toggle invert window on|off   # explicit state
omarchy toggle invert desktop --status # print JSON status
```

## How it works

Hyprland exposes one screen shader (`decoration:screen_shader`) per output and
applies it after rendering. There is no per-window shader hook, so both modes
share that single slot: `hypr/invert.lua` owns it and generates the correct GLSL
as the switches flip, masking to the focused window's rectangle via the
`wl_output` uniform and `v_texcoord`.

Because the two switches are independent, turning **both on** cancels the
inversion inside the focused window — a normally-colored window on an inverted
desktop, which is the useful combination for reading one photo or video on a
screen you have otherwise darkened.

### Technical constraints

- **Damage tracking.** Hyprland runs the screen shader over damaged regions
  only. A shader whose content changes mid-frame leaves old pixels untouched,
  producing an inverted/uninverted patchwork. Omarchy avoids this by turning
  `debug:damage_tracking` off for exactly as long as the picture could be wrong:
  continuously while window mode runs (the rectangle keeps moving), and for
  150 ms after any other switch. Your original setting is restored afterwards.
  Window inversion therefore costs GPU time the whole time it is on; desktop
  inversion costs it only briefly and then settles.

- **No move/resize event.** Hyprland has no window-moved or window-resized
  event, so the focused rectangle is re-read on a 100 ms timer. The timer runs
  only while window mode is on (a self-rescheduling oneshot, so switching off
  just ends the chain). Focus changes and fullscreen are event-driven and
  update immediately.

- **Rotated outputs.** The framebuffer is rotated relative to the layout
  coordinates a window reports. Window mode falls back to inverting the whole
  output in that case rather than placing a misaligned rectangle.

Both modes are runtime-only — like nightlight, they reset on Hyprland reload and
do not survive a logout.

## Installation

### Via `omarchy plugin add`

```bash
omarchy plugin add https://github.com/Maximilian-Maag/omarchy-invert
```

### Manual

```bash
# 1. Clone
git clone https://github.com/Maximilian-Maag/omarchy-invert ~/.config/omarchy/plugins/omarchy.invert

# 2. Link the Lua module so Hyprland can require it
mkdir -p ~/.config/hypr
cp ~/.config/omarchy/plugins/omarchy.invert/hypr/invert.lua ~/.config/hypr/invert.lua
# Or symlink: ln -sf ~/.config/omarchy/plugins/omarchy.invert/hypr/invert.lua ~/.config/hypr/invert.lua

# 3. Put the CLI binary on PATH
sudo cp ~/.config/omarchy/plugins/omarchy.invert/bin/omarchy-toggle-invert /usr/local/bin/
sudo chmod +x /usr/local/bin/omarchy-toggle-invert

# 4. Load the module from your Hyprland config
# Add to ~/.config/hypr/omarchy.lua (or any file Hyprland loads):
#   require("omarchy.invert")

# 5. Add keybindings to ~/.config/hypr/bindings.lua:
#   o.bind("SUPER + CTRL + U",       "Toggle focused window color inversion", "omarchy-toggle-invert window")
#   o.bind("SUPER + CTRL + ALT + U", "Toggle desktop color inversion",        "omarchy-toggle-invert desktop")
```

## Tested on

- Hyprland 0.56.2 at scale 1.5
- Single-monitor and multi-monitor setups
- Rotated output fallback confirmed

## License

MIT

<!-- policy-as-code -->

## Policy as code

Policies that only live in prose drift. This repository enforces its own in
`tools/policy_check.py` (dependency-free), configured by `policy.json`:

    python3 tools/policy_check.py            # every tracked file
    python3 tools/policy_check.py --changed  # only what you changed (pre-commit)
    python3 tools/policy_check.py --ci       # changed vs the base branch (CI)

`--changed` is wired into `.githooks/pre-commit` and the checks also run in
`.github/workflows/policy.yml`, so a violation fails the commit or the pull
request. After cloning, enable the hook once:

    git config core.hooksPath .githooks

Documented exceptions belong in `policy.json` under `allow`, each with a reason —
an exception you can read is a decision; a check nobody runs is decoration.
