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
--   PAD_LOG        1: log the joystick ports as well (J, S and P lines)
--   SPR_LOG        1: each frame's sprites by pattern (G lines), to count a game's shots
--   PAD_KIND       answer port A's reads as the core's pad table does (pocket_pad.sv), from the plan's
--                  "Pad <key>" inputs: two, md3, cap6, mag6, or auto (md3 while the program has had a
--                  strobe high in the last 55 frames, a second; two otherwise), whatever the slot device is
--   AUTO_HOLD      frames auto stays md3 after a strobe (55, the core's second; 1e9 for builds before 396c45d2)
--   AUTO_SWAP      frames: a drive the program ejects and leaves empty, with the motor off (E94007 bit 7),
--                  that long gets the set's next file after the highest one in a drive so far, as the
--                  core does it (0: off). Put in with the motor still on, Human68k says there's no disk.
--   AUTO_SWAP_ON   frames: the same, for a drive left ejected and empty that long whatever the motor
--                  (a game polling for its next disk with the motor running); 0, the default: off
--   AUTO_SWAP_EJ   frames: AUTO_SWAP_ON waits as well until that long after the program's last eject, or for
--                  the program to eject nothing for 2 s (111 frames), as the core does (6, its 0.1 s); 0: off
--   SWAP_PULSE     frames from an AUTO_SWAP choice to the disk being in: the core ejects for 0.42 s, mounts,
--                  and its disk emulation shows the disk 0.4 s later, 45 frames at 55.46 Hz (0, the default,
--                  puts it in at once)
--   SWAP_PULSE_ON  the same for AUTO_SWAP_ON, where the core mounts at once: 0.4 s, 22 frames. For the core's
--                  timing: AUTO_SWAP=60 AUTO_SWAP_ON=277 AUTO_SWAP_EJ=6 SWAP_PULSE=45 SWAP_PULSE_ON=22
--   DUMP_AT        frames, comma-separated, or "every:N": at each, what a save state would hold, as B lines
--                  (and MAME's picture d<frame>.png in SNAP_DIR), for tools/pocket/state_blocks.py
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
--   E frame unit             the program ejected a drive (E94005 with bit 5 and the drive's bit)
--   N frame unit             AUTO_SWAP chose the next file, SWAP_PULSE(_ON) frames before its L
--   L frame unit file m      AUTO_SWAP put a file in a drive, the motor (m) on or off then
--   D frame on               the drive motor (E94007 bit 7) turned on (1) or off (0)
--   F frame cmd unit c h r n eot   a read or write command to the FDC (READ DATA, WRITE DATA,
--                            WRITE DELETED; FORMAT's own bytes), from the CPU's writes to E94003: the
--                            data goes by DMA to the chip, so a tap sees only commands
--   J frame port n v0 v1 a b  with PAD_LOG: port n (0 A, 1 B, at E9A001/3) read a times this frame, first at
--                            raster line v0 and last at v1, b of them with the strobe (port C bit 4/5) high
--   S frame vpos value       with PAD_LOG: port C's top four bits changed (7, 6 trigger pull-downs; 5, 4 strobes)
--   G frame code:n ...       with SPR_LOG: the sprites shown at the frame's end (priority not 0), n of each
--                            pattern code (EB0004 + 8k, bits 0-7)
--   P pc                     with PAD_LOG: a program address reading a joystick port, the first time seen
--   B frame region n t...    with DUMP_AT: region (ram, gvram, tvram, eb) in n blocks of 1 KB, a token a block:
--                            0 all zero, x mixed, or the one long (8 hex digits) it repeats. ram, gvram and
--                            tvram are MAME's own storage (host order; GVRAM as the 65,536-colour mode shows
--                            it, whatever the mode), eb is EB0000-EBFFFF through the bus
--
-- Plan file, one action a line, # for comments:
--   <frame> press <field> <frames>      hold an input, by its name in MAME
--   <frame> repeat <every> <until> <field> <frames>   the same, again and again
--   <frame> disk <drive> <file>         put a file in a drive, "-" to take it out
-- Field names are matched whole, or else by what they start with ("Enter", "P1 A"). With PAD_KIND,
-- "Pad Right", "Pad Left", "Pad Down", "Pad Up", "Pad A", "Pad B", "Pad Run", "Pad Select", "Pad X",
-- "Pad Y", "Pad L" and "Pad R" are the Pocket's keys as the core's j has them, and the keys the core
-- sends with them are pressed too: Run is F1 as well; X, Y and L are SPACE, RETURN and ESC with the
-- two-button pad, X and L with Mega Drive 3 (core_top's keys_xl, keys_y).
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

-- uPD72065 commands by their low five bits, and their length with the command byte.
-- READ DATA (6), a write (5, 9) and FORMAT (13) are logged. Anything not listed is one byte.
local FDC_LEN = { [2]=9, [3]=3, [4]=2, [5]=9, [6]=9, [7]=2, [8]=1, [9]=9, [10]=2, [12]=9,
                  [13]=6, [15]=3, [17]=9, [25]=9, [29]=9 }
local fdc_cmd = {}
_G.tap_fdc = space:install_write_tap(0xe94002, 0xe94003, "census_fdc", function(a, d, m)
  if m & 0xff == 0 then return end
  table.insert(fdc_cmd, d & 0xff)
  local c = fdc_cmd[1] & 0x1f
  if #fdc_cmd >= (FDC_LEN[c] or 1) then
    if c == 5 or c == 6 or c == 9 or c == 13 then
      local b = fdc_cmd
      fh:write(fmt("F %d %d %d %d %d %d %d %d\n", frame, b[1], b[2] & 3, b[3] or 0, b[4] or 0,
                   b[5] or 0, b[6] or 0, b[7] or 0))
    end
    fdc_cmd = {}
  end
end)

-- The joystick ports: reads of PPI ports A and B, and port C's top four bits, set by a byte to E9A005 or
-- a bit at a time through the control word at E9A007.
local PAD = os.getenv("PAD_LOG") == "1"
local pad = { [0] = {}, [1] = {} }
local pcs = {}
-- The core's pad tables, j being {R, L, Y, X, Select, Run, B, A, up, down, left, right} from bit 11 down
-- and the result the six lines active low, {pin 7, pin 6, right, left, down, up}.
local KIND = os.getenv("PAD_KIND")
local vj, strobe_frame = 0, nil
local portc = 0
-- the core's Auto: a strobe (port C bit 4 or 5) high now or within the last second
local AUTO_HOLD = tonumber(os.getenv("AUTO_HOLD") or "55")
local function strobed()
  return (portc & 0x30) ~= 0 or (strobe_frame ~= nil and frame - strobe_frame <= AUTO_HOLD)
end
local function jb(n) return (vj >> n) & 1 end
local function lines(bits) -- bits from 5 down to 0, 1 = pressed
  local v = 0
  for i, b in ipairs(bits) do v = v | (b << (6 - i)) end
  return (~v) & 0x3f
end
local function pad_table(kind, str)
  if kind == "auto" then kind = strobed() and "md3" or "two" end
  if kind == "md3" then
    if str == 0 then return lines{jb(6), jb(4), 1, 1, jb(2), jb(3)} end
    return lines{jb(9), jb(5), jb(0), jb(1), jb(2), jb(3)}
  elseif kind == "cap6" then
    if str == 0 then return lines{jb(5), jb(4), jb(0), jb(1), jb(2), jb(3)} end
    return lines{jb(6), jb(10), jb(7), jb(8), jb(9), jb(11)}
  elseif kind == "mag6" then
    if str == 0 then return lines{jb(9), jb(8), jb(0), jb(1), jb(2), jb(3)} end
    return lines{jb(5), jb(4), jb(10), jb(11), 0, 0}
  end
  return lines{jb(5), jb(4), jb(0) | jb(6), jb(1) | jb(6), jb(2) | jb(7), jb(3) | jb(7)}
end
local VPAD = { Right = 0, Left = 1, Down = 2, Up = 3, A = 4, B = 5, Run = 6, Select = 7,
               X = 8, Y = 9, L = 10, R = 11 }

if KIND then
  -- port A as the core reads it: {1, pin 7, pin 6, 1, right, left, down, up}
  _G.tap_vpad = space:install_read_tap(0xe9a000, 0xe9a001, "census_vpad", function(a, d, m)
    if m & 0xff == 0 then return d end
    local j = pad_table(KIND, (portc >> 4) & 1)
    return (d & ~0xff) | 0x90 | (((j >> 4) & 3) << 5) | (j & 0xf)
  end)
end
if PAD then
  _G.tap_padr = space:install_read_tap(0xe9a000, 0xe9a003, "census_padr", function(a, d, m)
    local n = ((a & 3) >= 2) and 1 or 0
    if (a & 1) == 0 and (m & 0xff) == 0 then return end
    local p, v = pad[n], vpos()
    p.a = (p.a or 0) + 1
    p.v0 = p.v0 or v
    p.v1 = v
    if (portc >> (4 + n)) & 1 == 1 then p.b = (p.b or 0) + 1 end
    local pc = cpu.state["CURPC"].value
    if not pcs[pc] then pcs[pc] = true; fh:write(fmt("P %06x\n", pc)) end
  end)
end

if PAD or KIND then
  local function set_c(v)
    if PAD and (v ~ portc) & 0xf0 ~= 0 then fh:write(fmt("S %d %d %d\n", frame, vpos(), v & 0xf0)) end
    if (portc | v) & 0x30 ~= 0 then strobe_frame = frame end
    portc = v
  end
  _G.tap_padw = space:install_write_tap(0xe9a004, 0xe9a007, "census_padw", function(a, d, m)
    if m & 0xff == 0 then return end
    local v = d & 0xff
    -- the bus is 16 bits wide: the tap has the even address, the PPI's byte is the low one
    if (a & 6) == 4 then set_c(v)
    elseif (a & 6) == 6 and v & 0x80 == 0 then
      local b = (v >> 1) & 7
      set_c((v & 1 == 1) and (portc | (1 << b)) or (portc & ~(1 << b)))
    end
  end)
end

-- ------------------------------------------------------------------- the plan
local fields = {}
for tag, port in pairs(mach.ioport.ports) do
  for name, f in pairs(port.fields) do fields[name] = fields[name] or f end
end
local function field(name)
  if fields[name] then return fields[name] end
  local vk = name:match("^Pad (%a+)$")
  if vk and VPAD[vk] then
    local bit = 1 << VPAD[vk]
    return { set_value = function(self, v) if v ~= 0 then vj = vj | bit else vj = vj & ~bit end end }
  end
  for n, f in pairs(fields) do
    if n:sub(1, #name + 1) == name .. " " then return f end
  end
  error("no input called " .. name)
end
-- The keys the core sends from the pad, as core_top has them, kept each frame.
local PADKEYS = { { 6, "F1", "any" }, { 8, "Space", "xl" }, { 9, "Enter", "y" }, { 10, "ESC", "xl" } }
local padkey_on = {}
local function pad_keys()
  local kind = KIND == "auto" and (strobed() and "md3" or "two") or KIND
  for _, k in ipairs(PADKEYS) do
    local ok = k[3] == "any" or kind == "two" or (k[3] == "xl" and kind == "md3")
    local on = ok and jb(k[1]) == 1
    if on ~= (padkey_on[k[2]] or false) then fields[k[2]]:set_value(on and 1 or 0); padkey_on[k[2]] = on end
  end
end
local drives = {}
for tag, img in pairs(mach.images) do
  local n = tag:match(":upd72065:(%d):")
  if n then drives[tonumber(n)] = img end
end

-- The eject: a write to E94005 with bit 5 set ejects the drives whose bits (0-3) it holds.
local AUTO = tonumber(os.getenv("AUTO_SWAP") or "0")
local AUTO_ON = tonumber(os.getenv("AUTO_SWAP_ON") or "0")
local AUTO_EJ = tonumber(os.getenv("AUTO_SWAP_EJ") or "0")
local PULSE = tonumber(os.getenv("SWAP_PULSE") or "0")
local PULSE_ON = tonumber(os.getenv("SWAP_PULSE_ON") or "0")
-- AUTO_WRAP=1: past the set's last file the swap starts again from its first, as the core does,
-- never giving a drive the file the other holds or the one it has just lost.
local WRAP = os.getenv("AUTO_WRAP") == "1"
local empty_since, off_since, ejected, highest, set_base = {}, {}, {}, 0, nil
local last_eject, pending, held, nfiles = -100000, {}, {}, 0
for u, img in pairs(drives) do
  local base, k = (img.filename or ""):match("^(.*)_(%d+)%.dim$")
  if base then set_base = base; highest = math.max(highest, tonumber(k)); held[u] = tonumber(k) end
end
if set_base then
  while true do
    local f = io.open(fmt("%s_%d.dim", set_base, nfiles + 1), "rb")
    if not f then break end
    f:close()
    nfiles = nfiles + 1
  end
end
_G.tap_eject = space:install_write_tap(0xe94004, 0xe94005, "census_eject", function(a, d, m)
  if m & 0xff == 0 then return end
  local v = d & 0xff
  if v & 0x20 ~= 0 then
    for u = 0, 3 do
      if v & (1 << u) ~= 0 then ejected[u] = true; last_eject = frame; fh:write(fmt("E %d %d\n", frame, u)) end
    end
  end
end)
local motor = false
_G.tap_motor = space:install_write_tap(0xe94006, 0xe94007, "census_motor", function(a, d, m)
  if m & 0xff ~= 0 then
    local on = (d & 0x80) ~= 0
    if on ~= motor then fh:write(fmt("D %d %d\n", frame, on and 1 or 0)) end
    motor = on
  end
end)
local function next_file(u)
  local n = highest + 1
  if not WRAP then return n end
  for _ = 1, nfiles do
    if n > nfiles then n = 1 end
    if n ~= held[1 - u] and n ~= held[u] then return n end
    n = n + 1
  end
  return nil
end
local function swap_in(u, img)
  local n = next_file(u)
  local file = n and fmt("%s_%d.dim", set_base, n)
  local f = file and io.open(file, "rb")
  if f then
    f:close()
    img:load(file)
    highest = n
    held[u] = n
    ejected[u] = nil
    fh:write(fmt("L %d %d %s %s\n", frame, u, file:match("[^/]+$"), motor and "on" or "off"))
  end
end
local function auto_swap()
  if AUTO == 0 or not set_base then return end
  for u = 0, 1 do
    local img = drives[u]
    if pending[u] then
      -- the core's mount: chosen, then in PULSE frames later
      if frame >= pending[u] then
        pending[u] = nil
        if not img.exists then swap_in(u, img) end
      end
    elseif img and ejected[u] and not img.exists then
      empty_since[u] = empty_since[u] or frame
      if motor then off_since[u] = nil else off_since[u] = off_since[u] or frame end
      local since = frame - last_eject
      local off = off_since[u] and frame - off_since[u] >= AUTO
      if off or (AUTO_ON > 0 and frame - empty_since[u] >= AUTO_ON
                 and (AUTO_EJ == 0 or since == AUTO_EJ or since >= 111)) then
        local pulse = off and PULSE or PULSE_ON
        if pulse > 0 then
          pending[u] = frame + pulse
          fh:write(fmt("N %d %d\n", frame, u))
        else
          swap_in(u, img)
        end
        empty_since[u], off_since[u] = nil, nil
      end
    else
      empty_since[u], off_since[u] = nil, nil
    end
  end
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

-- ----------------------------------------------------------------- dumps
local DUMP, DUMP_EVERY = {}, nil
for v in (os.getenv("DUMP_AT") or ""):gmatch("[^,]+") do
  local e = v:match("^every:(%d+)$")
  if e then DUMP_EVERY = tonumber(e) else DUMP[assert(tonumber(v), "bad DUMP_AT")] = true end
end
local function blocks(name, s)
  local t = {}
  for o = 1, #s, 1024 do
    local b, w = s:sub(o, o + 1023), s:sub(o, o + 3)
    if b ~= string.rep(w, 256) then t[#t + 1] = "x"
    elseif w == "\0\0\0\0" then t[#t + 1] = "0"
    else t[#t + 1] = fmt("%08x", string.unpack("<I4", w)) end
  end
  fh:write(fmt("B %d %s %d %s\n", frame, name, #t, table.concat(t, " ")))
end
local function item(tag, name)
  local it = emu.item(mach.devices[tag].items[name])
  return it:read_block(0, it.size * it.count)
end
local function dump()
  blocks("ram", item(":ram", "0/m_pointer"))
  blocks("gvram", item(":", "0/m_gvram"))
  blocks("tvram", item(":", "0/m_tvram"))
  local t = {}
  for a = 0xeb0000, 0xebfffe, 2 do t[#t + 1] = string.pack(">I2", space:read_u16(a)) end
  blocks("eb", table.concat(t))
  if SNAP then scr:snapshot(fmt("%s/d%06d.png", SNAP, frame)) end
end

-- ----------------------------------------------------------------- each frame
local lastm = ""
_G.census_frame = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  if actions[frame] then
    for _, a in ipairs(actions[frame]) do a() end
  end
  auto_swap()
  if KIND then pad_keys() end
  fh:write(fmt("C %d %d %d %d %d\n", frame, gvw, gvr, tvw, tvr))
  if os.getenv("SPR_LOG") == "1" then
    local h, keys = {}, {}
    for k = 0, 127 do
      local a = 0xeb0000 + 8 * k
      if space:read_u16(a + 6) & 3 ~= 0 then
        local c = space:read_u16(a + 4) & 0xff
        if not h[c] then h[c] = 0; table.insert(keys, c) end
        h[c] = h[c] + 1
      end
    end
    table.sort(keys)
    local t = {}
    for _, c in ipairs(keys) do table.insert(t, fmt("%02x:%d", c, h[c])) end
    fh:write(fmt("G %d %s\n", frame - 1, table.concat(t, " ")))
  end
  if PAD then
    for n = 0, 1 do
      local p = pad[n]
      if p.a then fh:write(fmt("J %d %d %d %d %d %d\n", frame - 1, n, p.v0, p.v1, p.a, p.b or 0)) end
      pad[n] = {}
    end
  end
  gvw, gvr, tvw, tvr = 0, 0, 0, 0
  local m = fmt("%d %d %.3f", scr.width, scr.height, 1 / scr.frame_period)
  if m ~= lastm then lastm = m; fh:write(fmt("M %d %s\n", frame, m)) end
  if DUMP[frame] or (DUMP_EVERY and frame % DUMP_EVERY == 0) then dump() end
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
