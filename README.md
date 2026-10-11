# omarchy-invert

Colour effects for [Omarchy](https://omarchy.org/) — cycle the focused window or
the whole desktop through colour inversion and a maximum-contrast
yellow-on-black mode, without leaving the keyboard.

Each scope holds one of three **effects** and the shortcut cycles through them:

| Effect | What it does |
|--------|--------------|
| `off` | pixels untouched |
| `invert` | every channel flipped (`1 - rgb`) |
| `contrast` | luminance mapped to **yellow on black** — the accessibility mode for low vision / maximum readability |

| Hotkey | Action |
|--------|--------|
| `Super + Ctrl + U` | Cycle the focused window: `off → invert → contrast → off` |
| `Super + Ctrl + Alt + U` | Cycle the whole desktop: `off → invert → contrast → off` |

Both scopes are also available as CLI commands:

```bash
omarchy toggle invert window            # cycle the focused window
omarchy toggle invert desktop           # cycle the whole desktop
omarchy toggle invert window contrast   # select an effect: off|invert|contrast
omarchy toggle invert window on|off     # on = invert, off = off
omarchy toggle invert desktop --status  # print JSON status
```

`--status` prints `{"mode": "<scope>", "effect": "<off|invert|contrast>", "enabled": <bool>}`.


## How it works

Hyprland exposes one screen shader (`decoration:screen_shader`) per output and
applies it after rendering. There is no per-window shader hook, so every effect
shares that single slot: `hypr/invert.lua` owns it and generates the correct GLSL
as the effects change, masking to each pinned window's rectangle via the
`wl_output` uniform and `v_texcoord`.

The generated shader carries an integer `mode` (0 off, 1 invert, 2 contrast) for
the desktop and one rectangle clause per pinned window, each overriding the mode
inside its rectangle:

```glsl
int mode = 0;                                 // desktop effect
if (wl_output == 0 && v_texcoord.x >= … ) {   // pinned window rectangle
  mode = 2;
}
vec3 rgb = pixel.rgb;
if (mode == 1) {
  rgb = vec3(1.0) - rgb;                      // invert
} else if (mode == 2) {
  float luma = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
  rgb = vec3(smoothstep(0.15, 0.85, luma)) * vec3(1.0, 1.0, 0.0);  // yellow on black
}
fragColor = vec4(rgb, pixel.a);
```

The two scopes combine as *the pinned window's effect wins inside its own
rectangle; the desktop effect applies everywhere else*. One special case survives
from the original plugin because it is genuinely useful: desktop `invert` +
window `invert` cancel, leaving that window normally-coloured on an otherwise
inverted desktop (the combination for reading one photo or video on a screen you
have otherwise darkened). Contrast always wins — it is the accessibility effect
and should never silently disappear.

### The contrast effect

`contrast` is the accessibility mode. It discards colour and maps luminance to
yellow on black: `smoothstep(0.15, 0.85, luma)` compresses the luminance into
0–1 with an S-curve, so mid-tones are pushed apart, then that value becomes the
yellow channel — bright pixels glow yellow, dark pixels go black. The band
(0.15–0.85) is a compromise: hard enough to maximise legibility of text and UI
chrome, soft enough to keep photos and anti-aliased edges from collapsing into
two-tone blocks.


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
#   o.bind("SUPER + CTRL + U",       "Cycle focused window: off / invert / high-contrast", "omarchy-toggle-invert window")
#   o.bind("SUPER + CTRL + ALT + U", "Cycle desktop: off / invert / high-contrast",        "omarchy-toggle-invert desktop")
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

    make test              # every test kind CI runs (policy, unit, regression, integration, lua, shell, mutation)
    make check             # the same minus the slow mutation pass
    python3 tools/policy_check.py            # every tracked file
    python3 tools/policy_check.py --changed  # only what you changed (pre-commit)
    python3 tools/policy_check.py --ci       # changed vs the base branch (CI)

`--changed` is wired into `.githooks/pre-commit` and the checks also run in
`.github/workflows/policy.yml`, so a violation fails the commit or the pull
request. After cloning, enable the hook once:

    git config core.hooksPath .githooks

Documented exceptions belong in `policy.json` under `allow`, each with a reason —
an exception you can read is a decision; a check nobody runs is decoration.
