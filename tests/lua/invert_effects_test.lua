-- Unit tests for hypr/invert.lua's effect + shader logic.
--
-- The module is pure Lua apart from the global `hl` API Hyprland injects, so it
-- is loaded here against a stub `hl` (in-memory windows, recorded config writes,
-- queued timers) plus a stub default.hypr.paths. The generated GLSL is read back
-- from the state file the module writes, so the tests assert the SHADER ACTUALLY
-- PRODUCED, not a helper's return value.
--
-- Run: lua tests/lua/invert_effects_test.lua <plugin-dir>
--   (the plugin dir is needed to put hypr/ on package.path; XDG_STATE_HOME must
--    point at a writable scratch directory.)

local plugin_dir = arg[1]
if not plugin_dir then
  io.stderr:write("usage: lua invert_effects_test.lua <plugin-dir>\n")
  os.exit(2)
end

local state_home = os.getenv("XDG_STATE_HOME")
local scratch = nil
if not state_home or state_home == "" then
  -- Self-sufficient when run bare (`lua tests/lua/invert_effects_test.lua .`).
  scratch = (os.getenv("TMPDIR") or "/tmp")
    .. "/invert-lua-" .. tostring(os.time()) .. "-" .. tostring(math.random(1000000))
  os.execute("mkdir -p '" .. scratch .. "'")
  state_home = scratch
end

-- The module is loaded by its filename (`hypr/invert.lua`) rather than by its
-- Hyprland require name, so find it directly.
package.path = plugin_dir .. "/hypr/?.lua;" .. package.path

-- Faithful stand-in for default.hypr.paths, reading the same env vars.
package.preload["default.hypr.paths"] = function()
  return { home = os.getenv("HOME"), state_home = state_home }
end

local state_dir = state_home .. "/omarchy"
local shader_file = state_dir .. "/invert.frag"
local status_file = state_dir .. "/invert.status"

-- The module writes into <state>/omarchy, which Hyprland's session creates; the
-- scratch dir here does not, so make it up front.
os.execute("mkdir -p '" .. state_dir .. "'")

-- ── tiny test framework ─────────────────────────────────────────────────────
local passed, failed = 0, 0
local function check(cond, msg)
  if cond then
    passed = passed + 1
    io.write("ok: ", msg, "\n")
  else
    failed = failed + 1
    io.write("FAIL: ", msg, "\n")
  end
end
local function contains(haystack, needle, msg)
  check(haystack ~= nil and haystack:find(needle, 1, true) ~= nil,
        msg .. " [want '" .. needle .. "']")
end
local function not_contains(haystack, needle, msg)
  check(haystack == nil or haystack:find(needle, 1, true) == nil,
        msg .. " [absent '" .. needle .. "']")
end

-- ── stub Hyprland API ───────────────────────────────────────────────────────
local windows = {}
local active = nil
local shader_calls = {}   -- every decoration.screen_shader value written
local damage_calls = {}   -- every debug.damage_tracking value written
local border_calls = {}   -- every general.col.active_border value written
local damage_current = 2
local timers = {}
local handlers = {}

-- Stand-in for the theme's active border: a gradient table, exactly the shape
-- Hyprland's hl.get_config returns (colors as AARRGGBB hex strings + angle).
local THEME_BORDER = { angle = 45.0, colors = { "0xEE26A269", "0xEE2EC27E" } }

hl = {
  get_windows = function() return windows end,
  get_active_window = function() return active end,
  config = function(t)
    if t.decoration and t.decoration.screen_shader ~= nil then
      shader_calls[#shader_calls + 1] = t.decoration.screen_shader
    end
    if t.debug and t.debug.damage_tracking ~= nil then
      damage_current = t.debug.damage_tracking
      damage_calls[#damage_calls + 1] = t.debug.damage_tracking
    end
    if t.general and t.general.col and t.general.col.active_border ~= nil then
      border_calls[#border_calls + 1] = t.general.col.active_border
    end
  end,
  get_config = function(name)
    if name == "debug.damage_tracking" then return damage_current end
    if name == "general:col.active_border" then return THEME_BORDER end
    return nil
  end,
  timer = function(fn) timers[#timers + 1] = fn end,
  on = function(ev, fn) handlers[ev] = fn end,
}

local function last_shader()
  return shader_calls[#shader_calls]
end

local function shader_text()
  local f = io.open(shader_file, "r")
  if not f then return "" end
  local s = f:read("a")
  f:close()
  return s
end

local function status_text()
  local f = io.open(status_file, "r")
  if not f then return "" end
  local s = f:read("a")
  f:close()
  return s
end

local function flush_timers()
  local q = timers
  timers = {}          -- timers scheduled by these are left for the next flush
  for _, fn in ipairs(q) do fn() end
end

local function mkwin(addr, x, y, w, h, opts)
  opts = opts or {}
  local ws_id = opts.ws or 1
  local mon = {
    id = opts.output or 0,
    transform = opts.transform or 0,
    position = { x = opts.mon_x or 0, y = opts.mon_y or 0 },
    size = { width = opts.mon_w or 1920, height = opts.mon_h or 1080 },
    scale = opts.scale or 1.0,
    active_workspace = { id = opts.active_ws or 1 },
  }
  return {
    address = addr,
    hidden = opts.hidden or false,
    at = { x = x, y = y },
    size = { x = w, y = h },
    monitor = mon,
    workspace = { id = ws_id },
  }
end

-- Fresh module + clean observation buffers.
local function reset()
  windows = {}
  active = nil
  shader_calls = {}
  damage_calls = {}
  border_calls = {}
  damage_current = 2
  timers = {}
  handlers = {}
  os.remove(shader_file)
  package.loaded["invert"] = nil
  return require("invert")
end

-- ── scenarios ───────────────────────────────────────────────────────────────

-- 1. Default state: nothing applied, status reports both scopes off.
do
  local inv = reset()
  check(last_shader() == nil, "no effect set -> screen shader left untouched")
  contains(status_text(), "desktop=off", "default status: desktop off")
  contains(status_text(), "window=off", "default status: window off")
  check(type(inv.set) == "function" and type(inv.cycle) == "function",
        "module exposes set() and cycle()")
end

-- 2. Desktop cycle walks off -> invert -> contrast -> off.
do
  local inv = reset()

  inv.cycle("desktop")
  local s = shader_text()
  contains(s, "int mode = 1;", "cycle 1: desktop -> invert selects mode 1")
  contains(s, "rgb = vec3(1.0) - rgb;", "cycle 1: shader inverts rgb")
  not_contains(s, "if (wl_output ==", "cycle 1: full-desktop effect has no rect clause")
  contains(status_text(), "desktop=invert", "cycle 1: status desktop=invert")

  inv.cycle("desktop")
  s = shader_text()
  contains(s, "int mode = 2;", "cycle 2: desktop -> contrast selects mode 2")
  contains(s, "smoothstep(0.15, 0.85, luma)", "cycle 2: shader stretches luminance")
  contains(s, "vec3(1.0, 1.0, 0.0)", "cycle 2: shader paints yellow-on-black")
  contains(s, "textureSize(tex, 0)", "cycle 2: contrast samples neighbours")
  contains(s, "abs(ln - rn)", "cycle 2: contrast snaps thin vertical features to the opposite extreme")
  contains(status_text(), "desktop=contrast", "cycle 2: status desktop=contrast")

  inv.cycle("desktop")
  check(last_shader() == "", "cycle 3: desktop -> off clears the screen shader")
  contains(status_text(), "desktop=off", "cycle 3: status desktop=off")
end

-- 3. Explicit set() selects an effect, and rejects an unknown one.
do
  local inv = reset()
  inv.set("desktop", "contrast")
  contains(shader_text(), "int mode = 2;", "set('desktop','contrast') selects mode 2")

  local before = #shader_calls
  inv.set("desktop", "purple")
  check(#shader_calls == before, "an unknown effect is a no-op")
  contains(shader_text(), "int mode = 2;", "an unknown effect leaves the state alone")
end

-- 4. Pinned window: rectangle math and mode selection.
do
  local inv = reset()
  windows = { mkwin("0xaa", 100, 200, 800, 600) }
  active = windows[1]

  inv.cycle("window")
  local s = shader_text()
  contains(s, "    mode = 1;", "pinned window carries mode 1 (invert)")
  contains(s, "if (wl_output == 0 && v_texcoord.x >= 0.052083 && v_texcoord.x <= 0.468750",
           "rect x range is normalised to the output")
  contains(s, "v_texcoord.y >= 0.185185 && v_texcoord.y <= 0.740741",
           "rect y range is normalised to the output")
  contains(status_text(), "window=invert", "status window=invert while focused+pin")

  -- Second cycle: contrast on the same window.
  inv.cycle("window")
  contains(shader_text(), "    mode = 2;", "second window cycle -> contrast")

  -- Third cycle: unpin.
  inv.cycle("window")
  check(last_shader() == "", "third window cycle unpins -> shader cleared")
  contains(status_text(), "window=off", "third window cycle: status window=off")
end

-- 5. desktop invert + window invert cancel; contrast always wins.
do
  local inv = reset()
  windows = { mkwin("0xaa", 0, 0, 400, 300) }
  active = windows[1]

  inv.set("desktop", "invert")
  inv.set("window", "invert")
  contains(shader_text(), "    mode = 0;",
           "desktop invert + window invert cancels inside the rectangle")

  inv.set("window", "contrast")
  contains(shader_text(), "    mode = 2;",
           "window contrast overrides an inverted desktop")
  contains(shader_text(), "int mode = 1;", "desktop stays inverted outside the rectangle")
end

-- 6. Several windows, each with its own effect.
do
  local inv = reset()
  local a = mkwin("0xaa", 0, 0, 400, 300)
  local b = mkwin("0xbb", 500, 0, 400, 300)
  windows = { a, b }

  active = a
  inv.set("window", "invert")
  active = b
  inv.set("window", "contrast")

  local s = shader_text()
  contains(s, "    mode = 1;", "window A keeps its invert effect")
  contains(s, "    mode = 2;", "window B keeps its contrast effect")
  check(select(2, s:gsub("if %(wl_output == ", "")) == 2,
        "one rectangle clause per pinned window")
end

-- 7. Rotated output falls back to a whole-output clause.
do
  local inv = reset()
  windows = { mkwin("0xaa", 0, 0, 400, 300, { transform = 1 }) }
  active = windows[1]
  inv.set("window", "contrast")
  local s = shader_text()
  contains(s, "if (wl_output == 0) {", "rotated output: whole-output clause")
  not_contains(s, "v_texcoord.x >=", "rotated output: no rectangle coordinates")
  contains(s, "    mode = 2;", "rotated output still applies the effect")
end

-- 8. Hidden windows and windows on another workspace are not covered.
do
  local inv = reset()
  local hidden = mkwin("0xaa", 0, 0, 400, 300, { hidden = true })
  local other_ws = mkwin("0xbb", 0, 0, 400, 300, { ws = 2, active_ws = 1 })
  windows = { hidden, other_ws }

  active = hidden
  inv.set("window", "invert")
  check(last_shader() == nil, "a hidden pinned window applies nothing")

  active = other_ws
  inv.set("window", "invert")
  check(last_shader() == nil, "a pinned window on another workspace applies nothing")
end

-- 9. A closed window is dropped from the pin set.
do
  local inv = reset()
  local w = mkwin("0xaa", 0, 0, 400, 300)
  windows = { w }
  active = w
  inv.set("window", "invert")
  contains(shader_text(), "    mode = 1;", "pin applied before the window closes")

  -- Window goes away; the active-window event runs apply().
  windows = {}
  handlers["window.active"]()
  check(last_shader() == "", "closing the window clears its effect")

  -- Re-adding it must NOT resurrect the pin.
  windows = { mkwin("0xaa", 0, 0, 400, 300) }
  handlers["window.active"]()
  check(last_shader() == "", "a closed window's pin is dropped, not resurrected")
end

-- 10. Damage tracking is suspended while an effect is live and restored after.
do
  local inv = reset()
  inv.set("desktop", "invert")
  check(#damage_calls >= 1 and damage_calls[1] == 0,
        "damage tracking is suspended while an effect is on")

  inv.set("desktop", "off")
  flush_timers()
  check(damage_current == 2, "damage tracking is restored once the effect settles")
end

-- 11. cycle('window') without a focused window is a harmless no-op.
do
  local inv = reset()
  inv.cycle("window")
  check(last_shader() == nil, "cycling with no focused window does nothing")
end

-- 12. Contrast forces a bright-yellow focused border and restores the theme's.
do
  local inv = reset()
  inv.set("desktop", "contrast")
  check(#border_calls == 1 and border_calls[1] == "rgba(ffff00ff)",
        "desktop contrast forces the active border to bright yellow")

  inv.set("desktop", "off")
  check(#border_calls == 2 and border_calls[2] == THEME_BORDER,
        "leaving contrast restores the theme's active border")
end

-- 13. A contrast-pinned window forces the border too.
do
  local inv = reset()
  windows = { mkwin("0xaa", 0, 0, 400, 300) }
  active = windows[1]
  inv.set("window", "contrast")
  check(#border_calls == 1 and border_calls[1] == "rgba(ffff00ff)",
        "a contrast window forces the active border to bright yellow")
  inv.set("window", "off")
  check(#border_calls == 2 and border_calls[2] == THEME_BORDER,
        "unpinning the last contrast window restores the theme's border")
end

-- 14. Invert leaves the border alone (it inverts to a visible complement).
do
  local inv = reset()
  inv.set("desktop", "invert")
  check(#border_calls == 0, "invert leaves the active border alone")
end

-- ── summary ─────────────────────────────────────────────────────────────────
if scratch then os.execute("rm -rf '" .. scratch .. "'") end
io.write(string.format("\n%d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
