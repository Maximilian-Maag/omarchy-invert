# Changelog

All notable changes to omarchy-invert are documented here.

## [1.1.0] — 2026-10-08

### Added
- Test harness: policy as code plus unit, regression, integration, shell and
  mutation tests, with `tools/run_tests.sh` as the single entry point and CI
  running it (.github/workflows/test.yml). Mutation score is enforced at >= 0.80,
  and no source file may be left neither mutated nor exempted with a reason.

## [1.0.0] — 2026-10-08

### Added
- Color inversion for the focused window (`Super+Ctrl+U`) and for the whole desktop
  (`Super+Ctrl+Alt+U`), also available as
  `omarchy toggle invert window|desktop [on|off|--status]`.
- `hypr/invert.lua` owns Hyprland's single `decoration:screen_shader` slot and
  generates the GLSL for both switches, masking to the focused window's rectangle
  via the `wl_output` uniform and `v_texcoord`; enabling both cancels out.

Initial release.
