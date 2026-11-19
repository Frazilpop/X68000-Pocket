# Third-party code and licences

This core is **GPL-3.0** as a whole, as Puu-san's core it is built on is.
This file lists each part and what its licence asks for.

## Fetched by `tools/bootstrap.sh`

These land in `third_party/`, pinned in `deps.lock`, and are never committed.

| Component | Licence | Used for |
|---|---|---|
| [MiSTer-devel/X68000_MiSTer](https://github.com/MiSTer-devel/X68000_MiSTer) | GPL-3.0 | The upstream of `rtl/`, read for its fixes, and a second reference in simulation |
| [jtfpga/fx68k](https://github.com/jtfpga/fx68k) | GPL-3.0-or-later | The 68000 in simulation (`hdl/verilator`, which Verilator can read) |
| [agg23/analogue-pocket-utils](https://github.com/agg23/analogue-pocket-utils) | MIT | Pocket shell IP: the I2S audio out and its sync FIFO, built into the core |
| [mamedev/mame](https://github.com/mamedev/mame) (a few files) | see below | The reference: its X68000 driver, and the disk list `hash/x68k_flop.xml` |

`tools/get-ghdl.sh` fetches [GHDL](https://github.com/ghdl/ghdl) 6.0.0
(GPL-2.0-or-later) into `build/tools/ghdl`. It translates the VHDL to Verilog
for the simulation only and is no part of the core.

### analogue-pocket-utils – MIT
© 2022 Adam Gastineau. Keep the notice.

### MAME
Nothing of MAME's code is in this repo. The bootstrap checks out only the
X68000 driver (`src/mame/sharp/x68k*`), three of its chips' devices and the
software list `hash/x68k_flop.xml`, to read and to compare against. The
scripts read the list at run time; `tools/pocket/build_rom.py` carries the
CRCs of the disks it builds as the list gives them. MAME as a whole is
GPL-2.0, and its files a mix, so check each file's header before taking
anything from it.

## In the tree

### Puu-san's X68000 core – GPL-3.0
Everything in `rtl/` but `rtl/pocket_mem/`, `rtl/FX68K/` and
`rtl/sound/IKAOPM/` is Puu-san's X68000 core as MiSTer-devel/X68000_MiSTer
has it, imported at `4ed1454` (2 Nov 2026), with the fixes MiSTer's
contributors made to it over the years. **Its VHDL files carry no headers.**
Their licence is the GPL-3.0 that repository added on 2 Nov 2026 with
Puu-san's agreement (MiSTer-devel/X68000_MiSTer#74), copied here as
`LICENSE`; this file is where that is said, so keep it with them.

The parts this port doesn't use stayed upstream (MiSTer's framework, the D88
disk path, SASI, SxSI, MIDI). What it cuts is done by generics on
`X68K_top`, and the changes made here are in this repo's history.
`rtl/xe1ap.v` (© 2022, 2025 David Shadoff, the XE-1AP and CyberStick
module) came with the import under the same licence; it is in the file list,
but nothing in this core uses it. The files that begin "megafunction wizard"
are Quartus's generated RAM and ROM wrappers, with Intel's (Altera's) notice
in them.

### fx68k – GPL-3.0-or-later
`rtl/FX68K/` is upstream's copy of Jorge Cwik's fx68k, the 68000. Its source
files carry only his copyright line; the licence, GPL version 3 or (at your
option) any later version, is in `fx68k.txt`, with `LICENSE` beside it.
Keep both with the files. The bootstrap links `microrom.mem` and
`nanorom.mem` into the repo root, where fx68k loads them from.

### IKAOPM – BSD-2-Clause
`rtl/sound/IKAOPM/` is Raki's (ika-musume) YM2151, © 2022 Raki, from
[ika-musume/IKAOPM](https://github.com/ika-musume/IKAOPM), as upstream's
tree has it. Upstream carries no notice for it, so its `LICENSE` is kept
beside the files: the copyright notice, the conditions and the disclaimer
go with any copy, source or binary.

### Analogue openFPGA core template – Analogue's licence
`pocket/src/fpga/apf/`, `core_bridge_cmd.v` and the Quartus project files are
Analogue's, under the licence in their headers (with Analogue's Pocket EULA),
which yields to the MIT or GNU licence wherever the two disagree. The
Quartus megafunction output beside them (`pin_ddio_clk`,
`mf_datatable`, `mf_ddio_bidir_12`) is Intel's generated code, and
`build_id_gen.tcl` is Altera's reference design (Altera Reference Design
License), trimmed by Analogue.

## Written for this core

Everything else under `rtl/pocket_mem/`, `pocket/`, `sim/` and `tools/` –
the Pocket shell (`core_top.v` and the `pocket_*` modules), the video RAMs
on PSRAM, the 48 kHz resampler and its filter taps
(`pocket_audio_poly.hex`, made by `tools/pocket/audio_poly.py`), the
simulation harness and the scripts – is GPL-3.0-or-later, as each file's
header says.

`pocket/art/x68000-banner.png`, the platform image, is made from Sharp's
X68000 logo and a picture of the machine, © Sharp.

## ROMs and disks

No ROM image, boot ROM, disk image or anything taken from them is ever
committed or distributed. The boot ROM (Sharp's IPL and character ROM) and
the games' disks are the player's own, loaded at run time, and the tools
that read them write only to `build/`.
