-- SPDX-License-Identifier: GPL-3.0-or-later
-- X68000 (Pocket): trace the first N bus accesses from power-on, as the oracle for
-- the core's own trace.
--
--   tools/pocket/mame_oracle.sh tools/mame_x68k_bus_trace.lua none \
--       BUS_TRACE_OUT=build/mame/ipl_bus.txt BUS_TRACE_COUNT=200000
--
-- One access a line: <addr:06x> <R|W> <data:04x> <mask:04x>. addr is the byte address
-- of the 16-bit word (even), mask the lanes driven (ffff word, ff00 even byte, 00ff odd
-- byte). Lines starting '#' mark frames ("# frame N": MAME's vblank_begin of frame N).
-- The DMAC goes through the same space, so its accesses appear among the CPU's. Polling
-- and timers won't line up with a core's exactly: MAME isn't cycle-exact here.
--
-- Environment:
--   BUS_TRACE_OUT    output file
--   BUS_TRACE_COUNT  accesses to record (default 200000)
--   BUS_TRACE_FRAMES stop after this many frames whatever the count (default 3000)
--
-- With -autoboot_delay 0 the script runs at machine time 0, before the 68000 has run a
-- cycle, so the first two accesses are the reset vector's. Taps and notifiers are
-- GLOBALS: a local is collected and the callback stops with no error.

local MAX    = tonumber(os.getenv("BUS_TRACE_COUNT") or "200000")
local FRAMES = tonumber(os.getenv("BUS_TRACE_FRAMES") or "3000")
local OUT    = assert(os.getenv("BUS_TRACE_OUT"), "BUS_TRACE_OUT")

local mach  = manager.machine
local cpu   = mach.devices[":maincpu"]
local space = cpu.spaces["program"]

local fh = assert(io.open(OUT, "w"))
local n, done, frames = 0, false, 0
local t0 = os.clock()
local fmt = string.format

local function record(rw, offset, data, mask)
  if done then return end
  n = n + 1
  fh:write(fmt("%06x %s %04x %04x\n", offset & 0xffffff, rw, data & 0xffff, mask & 0xffff))
  if (n & 0x3fff) == 0 then fh:flush() end
  if n >= MAX then done = true end
end

print(fmt("bus trace: script at machine time %.6f, PC %06x", mach.time:as_double(), cpu.state["PC"].value))

_G.bt_r = space:install_read_tap(0, 0xffffff, "x68k_bt_r",
  function(offset, data, mask) record("R", offset, data, mask) end)
_G.bt_w = space:install_write_tap(0, 0xffffff, "x68k_bt_w",
  function(offset, data, mask) record("W", offset, data, mask) end)

-- Finishing happens here, never inside a tap: exiting from a tap tears the machine down
-- under the access in flight.
_G.bt_frame = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  if not done then fh:write(fmt("# frame %d\n", frames)) end
  if done or frames >= FRAMES then
    _G.bt_r:remove(); _G.bt_w:remove()
    fh:flush(); fh:close()
    print(fmt("bus trace: %d accesses in %d frames (%.3f s emulated), %.1f s CPU -> %s",
              n, frames, mach.time:as_double(), os.clock() - t0, OUT))
    mach:exit()
  end
end)
