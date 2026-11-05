-- SPDX-License-Identifier: GPL-3.0-or-later
-- X68000 (Pocket): log what a program does to the video hardware, frame by frame,
-- for tools/pocket/census.py to turn into modes, pages and PSRAM fetch figures.
--
--   tools/pocket/mame_oracle.sh tools/mame_x68k_census.lua bublbobl \
--       CENSUS_OUT=build/mame/census/bublbobl.log CENSUS_FRAMES=9000 \
--       SNAP_DIR=build/mame/census/bublbobl SNAP_STEP=300 \
--       PLAN=tools/pocket/plans/bublbobl.plan
--
-- Environment:
--   CENSUS_OUT     the log (a machine's whole run, streamed)
--   CENSUS_FRAMES  how many frames to run
--   SNAP_DIR, SNAP_STEP  MAME's picture every SNAP_STEP frames, as m<frame>.png
--   PLAN           inputs and disk swaps by frame, as below
--
-- The log, a line each, frame counted from power-on (a new frame starts at the
-- vblank that ended the last one, so a write in vblank belongs to the next
-- picture; vpos is MAME's raster line):
--   R frame vpos n value     CRTC register n (E80000 + 2n) changed
--   O frame vpos value       CRTC operation port (E80480): fast clear, raster copy
--   V frame vpos n value     video controller register n (E82400 + 0x100n) changed
--   H frame vpos value       system port E8E007 (the HRL bit)
--   C frame gvw gvr tvw tvr  bus accesses to GVRAM and TVRAM this frame
--   M frame w h hz           MAME's own screen when it changed
--
-- Plan file, one action a line, # for comments:
--   <frame> press <field> <frames>      hold an input, by its name in MAME
--   <frame> repeat <every> <until> <field> <frames>   the same, again and again
--   <frame> disk <drive> <file>         put a file in a drive, "-" to take it out
-- Field names are matched whole, or else by what they start with ("Enter", "P1 A").
--
-- Taps and notifiers are GLOBALS: a local is collected and the callback stops
-- with no error.

local OUT    = assert(os.getenv("CENSUS_OUT"), "CENSUS_OUT")
local FRAMES = tonumber(os.getenv("CENSUS_FRAMES") or "3600")
local SNAP   = os.getenv("SNAP_DIR")
local STEP   = tonumber(os.getenv("SNAP_STEP") or "300")
local PLANF  = os.getenv("PLAN")
local DISKS  = os.getenv("DISK_DIR") or "."

local mach  = manager.machine
local cpu   = mach.devices[":maincpu"]
local space = cpu.spaces["program"]
local scr   = mach.screens[":screen"]
local fmt   = string.format

local fh = assert(io.open(OUT, "w"))
local frame = 0
if SNAP then os.execute('mkdir -p "' .. SNAP .. '"') end

-- The Lua screen API has no vpos(): the time to line 0 gives it. scr.height is the
-- visible area here, so the total comes from the CRTC's own register.
local crtc, vc = {}, {}
local function vpos()
  local h = (crtc[4] or 567) + 1
  local lines = scr:time_until_pos(0) / scr.scan_period
  return math.floor(h - lines + 1e-6) % h
end

_G.tap_crtc = space:install_write_tap(0xe80000, 0xe8002f, "census_crtc", function(a, d, m)
  local n = ((a & 0xffffff) - 0xe80000) >> 1
  local v = ((crtc[n] or 0) & ~m) | (d & m)
  if v ~= crtc[n] then crtc[n] = v; fh:write(fmt("R %d %d %d %d\n", frame, vpos(), n, v)) end
end)
_G.tap_op = space:install_write_tap(0xe80480, 0xe80481, "census_op", function(a, d, m)
  fh:write(fmt("O %d %d %d\n", frame, vpos(), d & m))
end)
_G.tap_vc = space:install_write_tap(0xe82400, 0xe826ff, "census_vc", function(a, d, m)
  local n = ((a & 0xffffff) - 0xe82400) >> 8
  local v = ((vc[n] or 0) & ~m) | (d & m)
  if v ~= vc[n] then vc[n] = v; fh:write(fmt("V %d %d %d %d\n", frame, vpos(), n, v)) end
end)
local hrl
_G.tap_hrl = space:install_write_tap(0xe8e006, 0xe8e007, "census_hrl", function(a, d, m)
  if m & 0xff ~= 0 then
    local v = d & 0xff
    if v ~= hrl then hrl = v; fh:write(fmt("H %d %d %d\n", frame, vpos(), v)) end
  end
end)

local gvw, gvr, tvw, tvr = 0, 0, 0, 0
_G.tap_gw = space:install_write_tap(0xc00000, 0xdfffff, "census_gw", function() gvw = gvw + 1 end)
_G.tap_gr = space:install_read_tap(0xc00000, 0xdfffff, "census_gr", function() gvr = gvr + 1 end)
_G.tap_tw = space:install_write_tap(0xe00000, 0xe7ffff, "census_tw", function() tvw = tvw + 1 end)
_G.tap_tr = space:install_read_tap(0xe00000, 0xe7ffff, "census_tr", function() tvr = tvr + 1 end)

-- ------------------------------------------------------------------- the plan
local fields = {}
for tag, port in pairs(mach.ioport.ports) do
  for name, f in pairs(port.fields) do fields[name] = fields[name] or f end
end
local function field(name)
  if fields[name] then return fields[name] end
  for n, f in pairs(fields) do
    if n:sub(1, #name + 1) == name .. " " then return f end
  end
  error("no input called " .. name)
end
local drives = {}
for tag, img in pairs(mach.images) do
  local n = tag:match(":upd72065:(%d):")
  if n then drives[tonumber(n)] = img end
end

local actions = {}
if PLANF then
  for line in io.lines(PLANF) do
    line = line:gsub("#.*", "")
    local f, what, rest = line:match("^%s*(%d+)%s+(%S+)%s+(.-)%s*$")
    if f then
      f = tonumber(f)
      actions[f] = actions[f] or {}
      if what == "press" then
        local name, n = rest:match("^(.-)%s+(%d+)$")
        local fld = field(name)
        table.insert(actions[f], function() fld:set_value(1) end)
        local e = f + tonumber(n)
        actions[e] = actions[e] or {}
        table.insert(actions[e], function() fld:set_value(0) end)
      elseif what == "disk" then
        local d, file = rest:match("^(%d+)%s+(.+)$")
        local img = assert(drives[tonumber(d)], "no drive " .. d)
        if file == "-" then
          table.insert(actions[f], function() img:unload() end)
        else
          table.insert(actions[f], function() img:load(DISKS .. "/" .. file) end)
        end
      elseif what == "repeat" then
        local every, stop, name, n = rest:match("^(%d+)%s+(%d+)%s+(.-)%s+(%d+)$")
        local fld = field(name)
        for t = f, tonumber(stop), tonumber(every) do
          actions[t] = actions[t] or {}
          table.insert(actions[t], function() fld:set_value(1) end)
          local e = t + tonumber(n)
          actions[e] = actions[e] or {}
          table.insert(actions[e], function() fld:set_value(0) end)
        end
      else
        error("plan: " .. line)
      end
    end
  end
end

-- ----------------------------------------------------------------- each frame
local lastm = ""
_G.census_frame = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  if actions[frame] then
    for _, a in ipairs(actions[frame]) do a() end
  end
  fh:write(fmt("C %d %d %d %d %d\n", frame, gvw, gvr, tvw, tvr))
  gvw, gvr, tvw, tvr = 0, 0, 0, 0
  local m = fmt("%d %d %.3f", scr.width, scr.height, 1 / scr.frame_period)
  if m ~= lastm then lastm = m; fh:write(fmt("M %d %s\n", frame, m)) end
  if SNAP and frame % STEP == 0 then scr:snapshot(fmt("%s/m%06d.png", SNAP, frame)) end
  if frame % 3000 == 0 then
    fh:flush()
    print(fmt("%d of %d frames", frame, FRAMES))
  end
  if frame >= FRAMES then
    fh:close()
    mach:exit()
  end
end)
