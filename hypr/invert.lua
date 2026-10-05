-- Color inversion, for reading windows whose own contrast fights you.
--
-- Hyprland exposes exactly one screen shader (decoration:screen_shader) and runs
-- it over a whole output at the end of rendering, so both inversion modes have to
-- share that single slot. This module owns it; nothing else writes screen_shader.
--
-- Desktop mode inverts every pixel. Window mode inverts a set of explicitly
-- pinned windows. Each window is toggled independently: pressing the shortcut on
-- a window adds it to the set; pressing again removes it. Focus changes never
-- affect the set — only explicit toggles do.
--
-- Multiple windows can be inverted simultaneously. The shader is regenerated with
-- one rectangle clause per pinned visible window.
--
-- Turning both desktop and window mode on cancels the inversion inside each
-- pinned window, leaving them normally-coloured on an inverted desktop.

local paths = require("default.hypr.paths")

local state_dir = paths.state_home .. "/omarchy"
local shader_path = state_dir .. "/invert.frag"
local status_path = state_dir .. "/invert.status"

local poll_interval = 100

local invert = {}

local enabled = { desktop = false, window = false }
-- Set of window addresses currently pinned for inversion.
-- { [address] = true, ... }
local pinned = {}
local polling = false
local applied = nil
local damage_tracking = nil
local restore_pending = false

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

-- Build the list of visible rectangles for all pinned windows.
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

  for address in pairs(pinned) do
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

          if monitor.transform ~= 0 then
            -- Rotated output: invert the whole output rather than misplace a rect.
            targets[#targets + 1] = { output = monitor.id }
          else
            local width  = monitor.size.width  / monitor.scale
            local height = monitor.size.height / monitor.scale
            if width > 0 and height > 0 then
              local t = { output = monitor.id }
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

  -- If all pinned windows were closed, turn window mode off.
  if not has_pinned() then
    enabled.window = false
    write_file(status_path, string.format(
      "desktop=%s\nwindow=%s\n",
      tostring(enabled.desktop), tostring(enabled.window)
    ))
  end

  return targets
end

local function shader_source(targets)
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
    string.format("  bool inverted = %s;", enabled.desktop and "true" or "false"),
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
    table.insert(lines, "    inverted = !inverted;")
    table.insert(lines, "  }")
  end

  table.insert(lines, "  fragColor = inverted ? vec4(vec3(1.0) - pixel.rgb, pixel.a) : pixel;")
  table.insert(lines, "}")

  return table.concat(lines, "\n") .. "\n"
end

local function apply()
  local targets = {}
  if enabled.window then
    targets = pinned_targets()
  end

  if not enabled.desktop and #targets == 0 then
    if applied ~= nil then
      applied = nil
      hl.config({ decoration = { screen_shader = "" } })
    end
    return
  end

  local source = shader_source(targets)
  if source == applied then
    return
  end

  if write_file(shader_path, source) then
    applied = source
    hl.config({ decoration = { screen_shader = shader_path } })
  end
end

local function poll()
  if not enabled.window then
    polling = false
    return
  end
  apply()
  hl.timer(poll, { timeout = poll_interval, type = "oneshot" })
end

local function start_polling()
  if enabled.window and not polling then
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

  if enabled.window or enabled.desktop or restore_pending then
    return
  end

  restore_pending = true
  hl.timer(function()
    restore_pending = false
    if not enabled.window and not enabled.desktop then
      restore_damage_tracking()
    end
  end, { timeout = settle_duration, type = "oneshot" })
end

local function write_status()
  write_file(status_path, string.format(
    "desktop=%s\nwindow=%s\n",
    tostring(enabled.desktop), tostring(enabled.window)
  ))
end

-- set() for desktop mode works as before (on/off).
-- set('window', true/false) clears the entire pin set when turning off.
-- For per-window toggling use toggle('window') which pins/unpins the focused window.
function invert.set(mode, value)
  if enabled[mode] == nil then
    return
  end

  enabled[mode] = value and true or false

  if mode == "window" then
    if not enabled.window then
      -- Turning window mode fully off clears all pins.
      for k in pairs(pinned) do pinned[k] = nil end
    end
  end

  start_polling()
  apply()
  settle_damage_tracking()
  write_status()
end

-- toggle('window'): pins or unpins the currently focused window.
--   - If the focused window is already pinned → unpins it.
--   - If the focused window is not pinned → pins it and enables window mode.
--   - Focus on other windows is never affected.
--
-- toggle('desktop'): flips desktop mode on/off as before.
function invert.toggle(mode)
  if enabled[mode] == nil then
    return
  end

  if mode == "window" then
    local w = hl.get_active_window()
    if not w then
      return
    end

    if pinned[w.address] then
      -- Unpin this window.
      pinned[w.address] = nil
      if not has_pinned() then
        enabled.window = false
      end
    else
      -- Pin this window.
      pinned[w.address] = true
      enabled.window = true
    end

    start_polling()
    apply()
    settle_damage_tracking()
    write_status()
    return
  end

  -- Desktop mode: plain toggle.
  invert.set(mode, not enabled[mode])
end

hl.on("window.active",         apply)
hl.on("window.fullscreen",     apply)
hl.on("monitor.layout_changed", apply)
hl.on("workspace.active",      apply)

write_status()

return invert
