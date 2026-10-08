# Changelog

All notable changes to omarchy-invert are documented here.

## [1.0.0] — 2026-10-08

### Added
- Color inversion for the focused window (`Super+Ctrl+U`) and for the whole desktop
  (`Super+Ctrl+Alt+U`), also available as
  `omarchy toggle invert window|desktop [on|off|--status]`.
- `hypr/invert.lua` owns Hyprland's single `decoration:screen_shader` slot and
  generates the GLSL for both switches, masking to the focused window's rectangle
  via the `wl_output` uniform and `v_texcoord`; enabling both cancels out.

Initial release.
