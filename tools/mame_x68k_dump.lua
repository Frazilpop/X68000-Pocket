-- SPDX-License-Identifier: GPL-3.0-or-later
-- X68000 (Pocket): dump the video state at chosen frames with MAME's picture of that
-- frame, as the oracle for the RTL.
--
--   tools/pocket/mame_oracle.sh tools/mame_x68k_dump.lua bublbobl \
--       DUMP_DIR=build/mame/dump/bublbobl DUMP_FRAME=2400,3000
--
-- One subdirectory f<NNNNN> a frame, holding (big-endian words, as the 68000 reads them):
--   tvram.bin      E00000-E7FFFF
--   palette.bin    E82000-E823FF
--   sprites.bin    EB0000-EBFFFF, sprite registers, PCG and BG
--   gvram.bin      C00000-C7FFFF as the bus shows it in the mode the game has set, so a
--                  16-colour page reads as such; the mode is in regs.txt
--   crtc.bin       the CRTC's 24 registers as last written (MAME's save items don't reach
--                  Lua on this device, and reading some back through the bus masks them);
--                  one not yet written reads 0
--   regs.txt       those registers and the video controller's three, in hex
--   screen.png     MAME's picture
-- Everything is taken in the frame notifier, after that picture was rendered and before
-- any CPU runs again. Reads go through debug-free read_u16, with no side effects on
-- these areas.

local DIR = assert(os.getenv("DUMP_DIR"), "DUMP_DIR")
local WANT, LAST = {}, 0
for s in (os.getenv("DUMP_FRAME") or "600"):gmatch("[^,]+") do
  local n = assert(tonumber(s), "bad DUMP_FRAME")
  WANT[n] = true
  LAST = math.max(LAST, n)
end

local mach  = manager.machine
local space = mach.devices[":maincpu"].spaces["program"]
local scr   = mach.screens[":screen"]
local crtc  = {}
_G.dump_crtc = space:install_write_tap(0xe80000, 0xe8002f, "dump_crtc", function(a, d, m)
  local n = ((a & 0xffffff) - 0xe80000) >> 1
  crtc[n] = ((crtc[n] or 0) & ~m) | (d & m)
end)

local function bus(path, base, bytes)
  local f = assert(io.open(path, "wb"))
  local t = {}
  for a = base, base + bytes - 2, 2 do
    t[#t + 1] = string.pack(">I2", space:read_u16(a))
    if #t >= 8192 then f:write(table.concat(t)); t = {} end
  end
  f:write(table.concat(t))
  f:close()
end

local n = 0
_G.dump_frame = emu.add_machine_frame_notifier(function()
  n = n + 1
  if WANT[n] then
    local out = string.format("%s/f%05d", DIR, n)
    os.execute('mkdir -p "' .. out .. '"')
    bus(out .. "/tvram.bin", 0xe00000, 0x80000)
    bus(out .. "/palette.bin", 0xe82000, 0x400)
    bus(out .. "/sprites.bin", 0xeb0000, 0x10000)
    bus(out .. "/gvram.bin", 0xc00000, 0x80000)
    local f = assert(io.open(out .. "/crtc.bin", "wb"))
    local t = {}
    for i = 0, 23 do
      f:write(string.pack(">I2", crtc[i] or 0))
      t[#t + 1] = string.format("R%02d %04x", i, crtc[i] or 0)
    end
    f:close()
    for i = 0, 2 do
      t[#t + 1] = string.format("VC%d %04x", i, space:read_u16(0xe82400 + 0x100 * i))
    end
    f = assert(io.open(out .. "/regs.txt", "w"))
    f:write(table.concat(t, "\n") .. "\n")
    f:close()
    scr:snapshot(out .. "/screen.png")
    print("dump: frame " .. n .. " -> " .. out)
  end
  if n >= LAST then mach:exit() end
end)
