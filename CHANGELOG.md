# Changelog

All notable changes to omarchy-invert are documented here.

## [1.2.0] — 2026-10-11

### Added
- A **high-contrast effect** (yellow on black), for maximum readability when
  reading is the goal rather than color fidelity. Luminance is stretched by an
  S-curve (0.15–0.85) and mapped to yellow on black, so bright pixels become
  yellow and dark pixels black.
- The scopes now each hold an **effect** (`off`, `invert`, `contrast`) instead of
  a boolean, and the existing shortcuts **cycle** a scope through
  `off → invert → contrast → off`. `Super+Ctrl+U` cycles the focused window,
  `Super+Ctrl+Alt+U` cycles the whole desktop — the keys are unchanged.
- CLI: actions `invert` and `contrast` to select an effect explicitly, alongside
  the existing `on` (`= invert`), `off`, `toggle` (`= cycle`) and `--status`.

### Changed
- Combining scopes is now "the pinned window's effect wins inside its own
  rectangle; the desktop effect applies everywhere else", with one kept special
  case: desktop `invert` + window `invert` still cancel, so you can keep one
  window normally-colored on an inverted desktop.
- `--status` JSON gained an `effect` field (`{"mode", "effect", "enabled"}`); the
  live status file now stores effect names. A pre-1.2 boolean status file is
  still read correctly (`true` → `invert`).

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
