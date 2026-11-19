# Pocket tools

The scripts that make the game files for the Analogue Pocket, put them on the
card, and check the core against MAME. To play, none of this is needed: the
README's Installation is all it takes. Everything here writes into `build/`.
Run anything that opens your zips or disks with `python3 -I`, so Python can't
pick up stray files from the folder you're in.

## The boot ROM and the core's ten sets

```sh
python3 -I tools/pocket/build_rom.py all ~/Downloads build/pocket          # the boot ROM and every set
python3 -I tools/pocket/build_rom.py bublbobl,sf2ce ~/Downloads build/pocket
python3 -I tools/pocket/verify_rom.py all                                   # check them against MAME
```

`build_rom.py` writes `build/pocket/x68000_boot.rom` once – the same file as
MiSTer's `boot.rom`, and what goes on the card as
`Assets/x68000/common/boot.rom` – and `<set>_<n>.dim` for each disk of each
set. The boot ROM is 1 MB: MAME's `cgrom.dat` (0xC0000 bytes), 0x20000 zeros
for the SCSI ROM this model hasn't got, then `iplrom.dat` (IPL 1.0, 0x20000).
The sets are gradius, salamand, bublbobl, akumajo, ffight, parodius,
nemesis, sf2ce, ssf2 and chorensa, the ones the simulation and the census
use.

Files are found by CRC32 and size, never by name: loose in the folder, in
its zips, in zips inside those, or in `.7z` archives (through `7zz`). A disk
is written as MAME's software list `x68k_flop` has it, a DIM; an XDF (the
same disk with no header) is put under the standard header and checked to
come to MAME's CRC. Where no image on hand has MAME's CRC and the table names
another dump, the set still builds and the output says so loudly.

`verify_rom.py` runs MAME with `tools/mame_x68k_regions.lua` and compares the
boot ROM with MAME's own copy byte for byte, and each disk's CRC with MAME's
list, read at run time.

## A card of games

```sh
python3 -I tools/pocket/build_games.py <folder with the zips> build/pocket/games
bash tools/pocket/deploy.sh [/Volumes/NAME] [--overwrite-disks]
bash tools/pocket/deploy.sh --status
```

`build_games.py` lays out a folder a game, `<title>/<set>_<n>.dim`, as a
player would in `Assets/x68000/common/`: the ten at the top and a few hundred
arcade, action, sports and puzzle titles of MAME's list under `Games/`, each
only when every disk of the set is found, at most seven, each one the disk
emulator reads. It writes no JSON: the updaters' packager does that, or
`make_instances.py`, which goes in the core's folder
(`pocket/dist/Cores/frazilpop.X68000/`) for players without an updater and
writes the same files, byte for byte. `--messages` lists everything it can
say, with when each appears.

`deploy.sh` copies the core (`pocket/dist/`) to the card with the boot ROM
and the game folders, keeps any disk on the card that differs (a game may
have written to it) unless told `--overwrite-disks`, runs Pocket Sync's
instance packager over this core alone, then `card_entries.py`: a folder with
no disk and any entry that doesn't parse or names a missing file are taken
off, and the entries are written again in name order, so the card's directory
order is the list's. Everything is checked after copying, and the card is
left mounted.

`make_test_disk.py` makes test entries in `build/pocket/test/`: a disk that
writes to itself and to SRAM, so one look says a write and a save came back,
and a memory test of the RAM the core gives the machine.

## Checking against MAME

Run MAME through `mame_oracle.sh`, so every run repeats: the machine at IPL 1.0
from the boot ROM in `build/pocket`, fresh, empty settings and SRAM
(`SRAM_SEED=1` starts the SRAM as the core does), copies of the set's disks
(`build/pocket/<set>_<n>.dim`, or a game folder's with `SET_DIR=`), the first
two in drives 0 and 1, and the flags autoboot needs. `MAME=` changes which
MAME it runs. Each Lua script lists what it writes at its top.

```sh
# the bus from power-on, access for access, against the simulation's
tools/pocket/mame_oracle.sh tools/mame_x68k_bus_trace.lua none \
    BUS_TRACE_OUT=build/mame/ipl_bus.txt BUS_TRACE_COUNT=200000
python3 -I tools/pocket/diff_x68k_trace.py core.txt build/mame/ipl_bus.txt --resync 64

# the video state and MAME's picture at chosen frames, or every frame in a range
tools/pocket/mame_oracle.sh tools/mame_x68k_dump.lua bublbobl DUMP_DIR=build/mame/dump/bublbobl DUMP_FRAME=2400,3000
tools/pocket/mame_oracle.sh tools/mame_x68k_screens.lua bublbobl SCREENS_DIR=build/mame/screens/bublbobl FROM=2000 TO=2200

# each sound chip's own output and its writes
tools/pocket/mame_oracle.sh tools/mame_x68k_sound.lua bublbobl SOUND_DIR=build/mame/sound/bublbobl TO=3000
```

- `diff_x68k_trace.py` – two bus traces line for line; `--resync` gets a run past a timing loop's count and counts each break.
- `match_frames.py` – pairs a simulation's frames with MAME's (or another run's) by what they show, not by number, with a count of the dots that differ.
- `compare_frames.py` – two simulations' runs by each frame's checksum.
- `compare_sound.py` – the simulation's sound against MAME's: the FM register writes in order, the ADPCM bytes, the level. `compare_fm.py` sets the FM chip against MAME's YM2151 sample for sample, from the bench in `sim/sound/`.
- `audio_poly.py` – the 48 kHz resampler's filter taps, `pocket/src/fpga/core/pocket_audio_poly.hex`; `audio_alias.py` measures what resampling does to the FM chip's 62.5 kHz.

### The census

`tools/mame_x68k_census.lua` logs what a program does to the video hardware
frame by frame, and plays a plan of presses (`tools/pocket/plans/`) through
the core's own pad tables and keys (`PAD_KIND=two|md3|cap6|mag6|auto`), with
the core's disk swap modelled (`AUTO_SWAP`, `AUTO_WRAP`). `census.py` turns its
logs into the video modes each game uses and what they cost the core's
memory; `games_census.py` runs every set of the Games folder with each plan
and names the first input that changes its picture against a run with
nothing pressed.
