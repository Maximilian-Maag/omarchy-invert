-- Color inversion, for reading a window whose own contrast fights you.
--
-- Hyprland exposes exactly one screen shader (decoration:screen_shader) and runs
-- it over a whole output at the end of rendering, so both inversion modes have to
-- share that single slot. This module owns it; nothing else writes screen_shader.
--
-- Desktop mode inverts every pixel. Window mode inverts a specific pinned window's
-- rectangle. The pinned window is the one that was focused when the toggle was
-- pressed. Focus or workspace changes do not move the inversion to a new window —
-- they clear it, because the pinned window is no longer visible.

local paths = require("default.hypr.paths")

local state_dir = paths.state_home .. "/omarchy"
local shader_path = state_dir .. "/invert.frag"
local status_path = state_dir .. "/invert.status"

-- Hyprland has no window-moved or window-resized event, so a pinned window that
-- is dragged or resized only stays covered if its rectangle is re-read on a
-- timer. The timer runs only while window mode is on, and a tick that finds the
-- rectangle unchanged rewrites nothing.
local poll_interval = 100

local invert = {}

local enabled = { desktop = false, window = false }
-- Address of the specific window pinned for inversion. Set when window mode is
-- turned on, cleared when it is turned off.
local pinned_address = nil
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

-- Returns the rectangle for the pinned window, or nil if it is not currently
-- visible (different workspace, minimised, closed, or no window pinned).
--
-- On a transformed output Hyprland's framebuffer is rotated relative to the
-- layout coordinates a window reports, so a rectangle derived from them would
-- land somewhere else on screen. Rather than draw a misplaced box, window mode
-- inverts such an output whole: no rectangle, just the output id.
local function pinned_target()
  if not pinned_address then
    return nil
  end

  -- Find the pinned window by address among all open windows.
  local window = nil
  for _, w in ipairs(hl.get_windows()) do
    if w.address == pinned_address then
      window = w
      break
    end
  end

  if not window then
    -- Window was closed — turn off window mode.
    enabled.window = false
    pinned_address = nil
    write_file(status_path, string.format("desktop=%s\nwindow=%s\n", tostring(enabled.desktop), tostring(enabled.window)))
    return nil
  end

  local monitor = window.monitor
  if not monitor then
    return nil
  end

  -- Only invert if the pinned window is on the currently visible workspace of
  -- its monitor. If the user has switched away, the rectangle would land on
  -- whatever is at those screen coordinates on the active workspace.
  local active_ws = monitor.active_workspace
  if active_ws and window.workspace and window.workspace.id ~= active_ws.id then
    return nil
  end

  -- Hidden / minimised windows are not on screen.
  if window.hidden then
    return nil
  end

  local target = { output = monitor.id }
  if monitor.transform ~= 0 then
    return target
  end

  local width = monitor.size.width / monitor.scale
  local height = monitor.size.height / monitor.scale
  if width <= 0 or height <= 0 then
    return target
  end

  target.left   = (window.at.x - monitor.position.x) / width
  target.top    = (window.at.y - monitor.position.y) / height
  target.right  = target.left + window.size.x / width
  target.bottom = target.top  + window.size.y / height

  return target
end

local function shader_source(target)
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

  if target then
    if target.left then
      table.insert(
        lines,
        string.format(
          "  if (wl_output == %d && v_texcoord.x >= %.6f && v_texcoord.x <= %.6f && v_texcoord.y >= %.6f && v_texcoord.y <= %.6f) {",
          target.output,
          target.left,
          target.right,
          target.top,
          target.bottom
        )
      )
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
  local target = nil
  if enabled.window then
    target = pinned_target()
  end

  if not enabled.desktop and not target then
    if applied ~= nil then
      applied = nil
      hl.config({ decoration = { screen_shader = "" } })
    end

    return
  end

  local source = shader_source(target)
  if source == applied then
    return
  end

  if write_file(shader_path, source) then
    applied = source
    -- Hyprland recompiles the shader whenever the option is set, even when the
    -- path has not changed, so rewriting this one file moves the rectangle.
    hl.config({ decoration = { screen_shader = shader_path } })
  end
end

-- A self-rescheduling oneshot rather than a repeating timer: turning window mode
-- off simply stops the chain, so there is no timer handle to hold or cancel.
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

-- Hyprland runs the screen shader over damaged regions only, and nothing tells it
-- that the shader's own output changed. Undamaged areas keep the pixels the
-- previous shader produced, so the screen breaks into inverted and uninverted
-- fragments. Hyprland's answer for a screen shader that changes is to turn damage
-- tracking off, which redraws whole frames continuously and costs GPU time.
--
-- So it goes off for exactly as long as the screen can still be wrong: for as
-- long as window mode runs (the rectangle keeps moving when the window is dragged
-- or resized), and for a moment after any other switch. The user's own setting is
-- what gets put back.
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
  write_file(status_path, string.format("desktop=%s\nwindow=%s\n", tostring(enabled.desktop), tostring(enabled.window)))
end

function invert.set(mode, value)
  if enabled[mode] == nil then
    return
  end

  enabled[mode] = value and true or false

  if mode == "window" then
    if enabled.window then
      -- Pin to the window that is focused right now.
      local w = hl.get_active_window()
      pinned_address = w and w.address or nil
    else
      pinned_address = nil
    end
  end

  start_polling()
  apply()
  settle_damage_tracking()
  write_status()
end

function invert.toggle(mode)
  if enabled[mode] == nil then
    return
  end

  -- For window mode: if already on but the focused window has changed,
  -- re-pin to the new window rather than turning off. This way one press
  -- always means "invert this window", not "toggle the previous one off".
  -- Pressing the shortcut on the same already-inverted window turns it off.
  if mode == "window" and enabled.window then
    local w = hl.get_active_window()
    local focused_address = w and w.address or nil
    if focused_address and focused_address ~= pinned_address then
      -- Move pin to the newly focused window.
      pinned_address = focused_address
      start_polling()
      apply()
      settle_damage_tracking()
      write_status()
      return
    end
  end

  invert.set(mode, not enabled[mode])
end

-- Window events: only re-apply for move/resize of the pinned window.
-- workspace.active fires when the user switches workspace — re-apply so the
-- shader clears if the pinned window is no longer visible.
hl.on("window.active", apply)
hl.on("window.fullscreen", apply)
hl.on("monitor.layout_changed", apply)
hl.on("workspace.active", apply)

write_status()

return invert
