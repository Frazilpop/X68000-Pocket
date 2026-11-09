-- SPDX-License-Identifier: GPL-3.0-or-later
-- X68000 (Pocket): each sound chip's own output from MAME, before its mix, for
-- tools/pocket/compare_sound.py.
--
--   tools/pocket/mame_oracle.sh tools/mame_x68k_sound.lua ffight \
--       SOUND_DIR=build/mame/sound/ffight TO=3000 -- -wavwrite build/mame/sound/ffight/mix.wav -samplerate 48000
--
-- In SOUND_DIR: ym2151.f32 (left and right, interleaved, at the chip's 62.5 kHz), okim6258.f32 (one
-- channel at whatever rate the machine has set it to) and index.txt, a line a sound update: the
-- machine's time in seconds, the frame number, then the samples each chip gave in it, so the ADPCM's
-- changing rate can be followed; writes.txt, every write to the FM chip (E90001, E90003), the ADPCM
-- (E92001, E92003) and the PPI's port C and control (E9A005, E9A007), DMA's included, as
-- "<machine time in us> <address> <byte>", the simulation's sound_writes.txt's form. The -wavwrite mix is taken with -sound none still on (nothing is
-- played aloud). Frame N is the Nth frame notification from power-on, as mame_x68k_screens.lua's.
-- With PLAN (and CENSUS_OUT, CENSUS_FRAMES) set, mame_x68k_census.lua runs beside it and plays the
-- plan's inputs; it then ends the run at CENSUS_FRAMES, and TO should be no less.
local DIR = os.getenv("SOUND_DIR") or "."
local TO  = tonumber(os.getenv("TO") or "3000")
os.execute('mkdir -p "' .. DIR .. '"')

local files = { [":ym2151"] = io.open(DIR .. "/ym2151.f32", "wb"), [":okim6258"] = io.open(DIR .. "/okim6258.f32", "wb") }
local index = io.open(DIR .. "/index.txt", "w")
for tag, _ in pairs(files) do manager.machine.sounds[tag].hook = true end

local writes = io.open(DIR .. "/writes.txt", "w")
local space = manager.machine.devices[":maincpu"].spaces["program"]
local function tap(lo, hi, name)
  _G["sound_tap_" .. name] = space:install_write_tap(lo, hi, "sound_" .. name, function(a, d, m)
    local lo_byte = (m & 0xff) ~= 0
    local addr = (a & 0xfffffe) | (lo_byte and 1 or 0)
    local b = lo_byte and (d & 0xff) or ((d >> 8) & 0xff)
    writes:write(string.format("%.3f %06x %02x\n", manager.machine.time:as_double() * 1e6, addr, b))
  end)
end
tap(0xe90000, 0xe90003, "opm")
tap(0xe92000, 0xe92003, "adpcm")
tap(0xe9a004, 0xe9a007, "ppi")

local n = 0
local pack = string.pack
_G.sound_update = emu.register_sound_update(function(t)
  local counts = {}
  for _, tag in ipairs({":ym2151", ":okim6258"}) do
    local v = t[tag]
    local h = files[tag]
    if v then
      local buf = {}
      if #v >= 2 then
        local l, r = v[1], v[2]
        for i = 1, #l do buf[i] = pack("<ff", l[i], r[i]) end
        counts[#counts + 1] = #l
      else
        local l = v[1]
        for i = 1, #l do buf[i] = pack("<f", l[i]) end
        counts[#counts + 1] = #l
      end
      h:write(table.concat(buf))
      h:flush()
    else
      counts[#counts + 1] = 0
    end
  end
  index:write(string.format("%.9f %d %d %d\n", manager.machine.time:as_double(), n, counts[1], counts[2]))
  index:flush()
end)

if os.getenv("PLAN") then
  dofile(debug.getinfo(1, "S").source:sub(2):gsub("[^/]*$", "") .. "mame_x68k_census.lua")
end

_G.sound_frames = emu.add_machine_frame_notifier(function()
  n = n + 1
  if n >= TO then
    for _, h in pairs(files) do h:close() end
    index:close()
    writes:close()
    manager.machine:exit()
  end
end)
