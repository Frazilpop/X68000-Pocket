-- SPDX-License-Identifier: GPL-3.0-or-later
-- X68000 (Pocket): MAME's picture for every frame in a range, as PNGs.
--
--   tools/pocket/mame_oracle.sh tools/mame_x68k_screens.lua bublbobl \
--       SCREENS_DIR=build/mame/screens/bublbobl FROM=2000 TO=2200 STEP=1
--
-- Frame N is the Nth frame notification from power-on, and the picture is
-- screen:snapshot() (not pixels(), which lags a frame inside the notifier).
-- It takes no inputs: mame_x68k_census.lua's SNAP_DIR does for a run with a plan file.
local DIR  = os.getenv("SCREENS_DIR") or "."
local FROM = tonumber(os.getenv("FROM") or "1")
local TO   = tonumber(os.getenv("TO") or "600")
local STEP = tonumber(os.getenv("STEP") or "1")
local scr  = manager.machine.screens[":screen"]
os.execute('mkdir -p "' .. DIR .. '"')
local n = 0
_G.screens_notifier = emu.add_machine_frame_notifier(function()
  n = n + 1
  if n >= FROM and n <= TO and ((n - FROM) % STEP) == 0 then
    scr:snapshot(string.format("%s/m%05d.png", DIR, n))
  end
  if n >= TO then manager.machine:exit() end
end)
