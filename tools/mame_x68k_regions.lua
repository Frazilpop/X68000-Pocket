-- SPDX-License-Identifier: GPL-3.0-or-later
-- X68000 (Pocket): dump the part of MAME's maincpu region the boot ROM stands for, so
-- tools/pocket/verify_rom.py can check it byte for byte.
--
--   tools/pocket/mame_oracle.sh tools/mame_x68k_regions.lua none DUMP_DIR=build/mame/regions
--
-- Writes boot.bin: F00000-FFFFFF of the region, the machine's addresses for the 1 MB
-- boot ROM. read_u32 gives the next four bytes in the 68000's order whichever way MAME
-- stores them, so byte 0 is the high byte of the first word.

local DIR = assert(os.getenv("DUMP_DIR"), "DUMP_DIR")
os.execute('mkdir -p "' .. DIR .. '"')
local r = assert(manager.machine.memory.regions[":maincpu"], "no maincpu region")
local f = assert(io.open(DIR .. "/boot.bin", "wb"))
local chunk = {}
for a = 0xf00000, 0xfffffc, 4 do
  chunk[#chunk + 1] = string.pack(">I4", r:read_u32(a))
  if #chunk >= 8192 then f:write(table.concat(chunk)); chunk = {} end
end
f:write(table.concat(chunk))
f:close()
manager.machine:exit()
