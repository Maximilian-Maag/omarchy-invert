-- Color effects, for reading windows whose own contrast fights you.
--
-- Three effects are available and they share Hyprland's single screen shader
-- (decoration:screen_shader), which runs over a whole output at the end of
-- rendering:
--
--   off       — the pixels untouched (no effect)
--   invert    — every channel flipped, 1 - rgb
--   contrast  — luminance mapped to yellow on black (maximum-contrast mode,
--               the accessibility one: bright pixels become yellow, dark
--               pixels black, with an S-curve that hardens the mid-tones)
--
-- Each of the two scopes carries one of these effects:
--
--   desktop — applies to every pixel of an output
--   window  — applies to each explicitly pinned window's rectangle
--
-- The scopes combine as follows. A pinned window's effect wins inside its own
-- rectangle; everywhere else on the output the desktop effect applies. One
-- special case is kept from the original plugin because it is genuinely useful:
-- desktop invert + window invert cancel, leaving that window normally-colored
-- on an otherwise inverted desktop. Contrast always wins (it is the
-- accessibility effect and should never silently disappear).
--
-- Windows are pinned per address, so several windows can carry effects at once
-- and each can differ. Pure focus changes never alter the set — only an
-- explicit cycle does.
--
-- The shortcuts cycle a scope through off -> invert -> contrast -> off.

local paths = require("default.hypr.paths")

local state_dir = paths.state_home .. "/omarchy"
local shader_path = state_dir .. "/invert.frag"
local status_path = state_dir .. "/invert.status"

local poll_interval = 100

-- Luminance band that the contrast effect stretches to full black/white range.
-- Values below CONTRAST_LO become pure black, above CONTRAST_HI pure yellow, so
-- text and UI chrome snap to maximum contrast while a gentle ramp in between
-- keeps photos and anti-aliased edges from turning into hard two-tone blocks.
local CONTRAST_LO = 0.15
local CONTRAST_HI = 0.85

local invert = {}

local effects = { off = true, invert = true, contrast = true }
local cycle_next = { off = "invert", invert = "contrast", contrast = "off" }

local desktop_effect = "off"
-- Set of window addresses currently pinned, each mapped to its effect.
-- { [address] = "invert" | "contrast", ... }
local pinned = {}
local polling = false
local applied = nil
local damage_tracking = nil
local restore_pending = false

local function effect_int(effect)
  if effect == "invert" then
    return 1
  elseif effect == "contrast" then
    return 2
  end
  return 0
end

-- Effective effect for a pinned window, given the current desktop effect.
-- The desktop-invert + window-invert pair cancels (the classic combination);
-- every other combination resolves to the window's own effect.
local function window_effect(win_effect)
  if win_effect == "invert" and desktop_effect == "invert" then
    return "off"
  end
  return win_effect
end

local function write_file(path, contents)
  local file = io.open(path, "w")
  if not file then
    return false
  end
  file:write(contents)
  file:close()
  return true
end

-- Returns true if there is at least one address in the pinned set.
local function has_pinned()
  for _ in pairs(pinned) do
    return true
  end
  return false
end

local function desktop_on()
  return desktop_effect ~= "off"
end

-- Build the list of visible rectangles for all pinned windows, each carrying
-- the already-resolved integer effect for its rectangle.
-- A window is visible if it is on the active workspace of its monitor and
-- not hidden/minimised.
local function pinned_targets()
  if not has_pinned() then
    return {}
  end

  -- Index all open windows by address for O(1) lookup.
  local by_address = {}
  for _, w in ipairs(hl.get_windows()) do
    by_address[w.address] = w
  end

  local targets = {}
  local closed = {}

  for address, effect in pairs(pinned) do
    local window = by_address[address]

    if not window then
      -- Window was closed — remove from set.
      closed[address] = true
    elseif not window.hidden then
      local monitor = window.monitor
      if monitor then
        local active_ws = monitor.active_workspace
        -- Only include if on the currently visible workspace.
        if not active_ws or not window.workspace
            or window.workspace.id == active_ws.id then

          local resolved = effect_int(window_effect(effect))
          if monitor.transform ~= 0 then
            -- Rotated output: apply over the whole output rather than misplace
            -- a rectangle.
            targets[#targets + 1] = { output = monitor.id, mode = resolved }
          else
            local width  = monitor.size.width  / monitor.scale
            local height = monitor.size.height / monitor.scale
            if width > 0 and height > 0 then
              local t = { output = monitor.id, mode = resolved }
              t.left   = (window.at.x - monitor.position.x) / width
              t.top    = (window.at.y - monitor.position.y) / height
              t.right  = t.left + window.size.x / width
              t.bottom = t.top  + window.size.y / height
              targets[#targets + 1] = t
            end
          end
        end
      end
    end
  end

  -- Remove closed windows from the pin set.
  for address in pairs(closed) do
    pinned[address] = nil
  end

  return targets
end

local function shader_source(targets, desktop)
  local lines = {
    "#version 300 es",
    "precision highp float;",
    "",
    "in vec2 v_texcoord;",
    "out vec4 fragColor;",
    "uniform sampler2D tex;",
    "uniform int wl_output;",
    "",
    "void main() {",
    "  vec4 pixel = texture(tex, v_texcoord);",
    string.format("  int mode = %d;", effect_int(desktop)),
  }

  for _, target in ipairs(targets) do
    if target.left then
      table.insert(lines, string.format(
        "  if (wl_output == %d && v_texcoord.x >= %.6f && v_texcoord.x <= %.6f && v_texcoord.y >= %.6f && v_texcoord.y <= %.6f) {",
        target.output, target.left, target.right, target.top, target.bottom
      ))
    else
      table.insert(lines, string.format("  if (wl_output == %d) {", target.output))
    end
    table.insert(lines, string.format("    mode = %d;", target.mode))
    table.insert(lines, "  }")
  end

  table.insert(lines, "  vec3 rgb = pixel.rgb;")
  table.insert(lines, "  if (mode == 1) {")
  table.insert(lines, "    rgb = vec3(1.0) - rgb;")
  table.insert(lines, "  } else if (mode == 2) {")
  table.insert(lines, "    float luma = dot(rgb, vec3(0.2126, 0.7152, 0.0722));")
  table.insert(lines, string.format(
    "    rgb = vec3(smoothstep(%.2f, %.2f, luma)) * vec3(1.0, 1.0, 0.0);",
    CONTRAST_LO, CONTRAST_HI
  ))
  table.insert(lines, "  }")
  table.insert(lines, "  fragColor = vec4(rgb, pixel.a);")
  table.insert(lines, "}")

  return table.concat(lines, "\n") .. "\n"
end

local function apply()
  local targets = {}
  if has_pinned() then
    targets = pinned_targets()
  end

  if not desktop_on() and #targets == 0 then
    if applied ~= nil then
      applied = nil
      hl.config({ decoration = { screen_shader = "" } })
    end
    return
  end

  local source = shader_source(targets, desktop_effect)
  if source == applied then
    return
  end

  if write_file(shader_path, source) then
    applied = source
    hl.config({ decoration = { screen_shader = shader_path } })
  end
end

local function poll()
  if not has_pinned() then
    polling = false
    return
  end
  apply()
  hl.timer(poll, { timeout = poll_interval, type = "oneshot" })
end

local function start_polling()
  if has_pinned() and not polling then
    polling = true
    hl.timer(poll, { timeout = poll_interval, type = "oneshot" })
  end
end

local settle_duration = 150

local function suspend_damage_tracking()
  if damage_tracking == nil then
    damage_tracking = hl.get_config("debug.damage_tracking") or 2
    hl.config({ debug = { damage_tracking = 0 } })
  end
end

local function restore_damage_tracking()
  if damage_tracking ~= nil then
    hl.config({ debug = { damage_tracking = damage_tracking } })
    damage_tracking = nil
  end
end

local function settle_damage_tracking()
  suspend_damage_tracking()

  if has_pinned() or desktop_on() or restore_pending then
    return
  end

  restore_pending = true
  hl.timer(function()
    restore_pending = false
    if not has_pinned() and not desktop_on() then
      restore_damage_tracking()
    end
  end, { timeout = settle_duration, type = "oneshot" })
end

-- The effect currently shown on the focused window: its pin if pinned, else off.
local function window_status_effect()
  local w = hl.get_active_window()
  if w and pinned[w.address] then
    return pinned[w.address]
  end
  return "off"
end

local function write_status()
  write_file(status_path, string.format(
    "desktop=%s\nwindow=%s\n",
    desktop_effect, window_status_effect()
  ))
end

local function refresh()
  start_polling()
  apply()
  settle_damage_tracking()
  write_status()
end

-- set(scope, effect): set an explicit effect on a scope.
--   set('desktop', 'off'|'invert'|'contrast')  — the whole output
--   set('window',  'off'|'invert'|'contrast')  — the focused window
-- 'off' on the window scope un-pins the focused window.
function invert.set(scope, effect)
  if not effects[effect] then
    return
  end

  if scope == "desktop" then
    desktop_effect = effect
    refresh()
    return
  end

  if scope == "window" then
    local w = hl.get_active_window()
    if not w then
      return
    end
    if effect == "off" then
      pinned[w.address] = nil
    else
      pinned[w.address] = effect
    end
    refresh()
    return
  end
end

-- cycle(scope): advance a scope through off -> invert -> contrast -> off.
--   cycle('desktop') — the whole output
--   cycle('window')  — the focused window (pin / re-effect / un-pin)
function invert.cycle(scope)
  if scope == "desktop" then
    invert.set("desktop", cycle_next[desktop_effect])
  elseif scope == "window" then
    local w = hl.get_active_window()
    if not w then
      return
    end
    local current = pinned[w.address] or "off"
    invert.set("window", cycle_next[current])
  end
end

-- Backwards-compatible alias: the original API exposed toggle() for both scopes.
invert.toggle = invert.cycle

-- A newly focused window changes what window scope reports, and may need the
-- rectangle moved before the next poll tick. Fullscreening keeps the same
-- window focused but resizes it, and a monitor coming or going renumbers
-- outputs, so the shader is regenerated on each.
local function on_change()
  apply()
  write_status()
end

hl.on("window.active",        on_change)
hl.on("window.fullscreen",    apply)
hl.on("monitor.layout_changed", apply)
hl.on("workspace.active",     apply)

write_status()

return invert
