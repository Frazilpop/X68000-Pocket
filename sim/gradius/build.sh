#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds the simulation of the machine into build/sim/<which>, again only for what changed.
#   bash sim/gradius/build.sh port         this tree, from core_top down
#   bash sim/gradius/build.sh upstream     upstream's own X68K_top at the pinned commit, the reference
# Then build/sim/<which>/run <options>; any wrong option lists them. sim/gradius/shell_test.py checks the shell.
set -euo pipefail
cd "$(dirname "$0")/../.."
which=$1
S=$PWD/sim/gradius
M=$PWD/sim/models
B=$PWD/build/sim/$which
echo "1 of 3 build steps: translating"
bash "$S/translate.sh" "$which"
echo "2 of 3 build steps: the sources"
mkdir -p "$B/fx68k"
if [ "$which" = port ]; then R=$PWD/rtl; else R=$PWD/third_party/x68000-mister/rtl; fi
# the fx68k Quartus builds, with its typedefs packed for Verilator (--noassert below)
sed 's/^typedef struct {/typedef struct packed {/' "$R/FX68K/fx68k.sv" > "$B/fx68k/fx68k.sv"
cp "$R/FX68K/microrom.mem" "$R/FX68K/nanorom.mem" "$B/gen/"
# the resampler's taps, read as Quartus reads them, from a folder called core beside the run's files
[ "$which" = port ] && ln -sfn "$PWD/pocket/src/fpga/core" "$B/gen/core"
# the FM chip: IKAOPM in this tree, jt51 in upstream's (its default)
if [ "$which" = port ]; then FM=$(ls "$R"/sound/IKAOPM/*.v); else FM=$(ls "$R"/sound/jt51/*.v); fi
VID=("$R/VIDEO/mister_sync.sv" "$R/VIDEO/x68k_linedoubler.sv" "$R/VIDEO/x68k_video_cdc.sv" "$R/VIDEO/x68k_video_window.sv" "$R/VIDEO/x68k_native_crtc.sv")
CPU=("$B/fx68k/fx68k.sv" "$R/FX68K/fx68kAlu.sv" "$R/FX68K/uaddrPla.sv")
BOARD=("$B/gen/x68k_top.sv" $FM "${VID[@]}" "${CPU[@]}" "$M/altsyncram.v" "$M/sdram_model.sv")
if [ "$which" = port ]; then
  C=$PWD/pocket/src/fpga/core; A=$PWD/pocket/src/fpga/apf; U=$PWD/third_party/pocket-utils/ip
  SRC=("$S/sim_port.sv" "$S/sim_stubs.sv" "$C/core_top.v" "$C/core_bridge_cmd.v" "$C/pocket_sync.sv" "$C/pocket_scanout.sv"
       "$C/pocket_diag.sv" "$C/pocket_audio_resample.sv" "$C/pocket_disk.sv" "$C/pocket_sram_slot.sv" "$C/pocket_pad.sv" "$C/pocket_kbd.sv" "$A/common.v" "$A/mf_datatable.v"
       "$U/sync_fifo.sv" "$U/sound_i2s.sv" "$M/psram_model.sv" "$PWD/rtl/pocket_mem/pocket_psram_bus.sv" "$PWD/rtl/pocket_mem/pocket_vram_cache.sv"
       "$PWD/rtl/pocket_mem/gvram_psram.sv" "$PWD/rtl/pocket_mem/tvram_psram.sv" "${BOARD[@]}")
  TOP=sim_port; DEF=(-DSIM_PORT)
else
  SRC=("$S/sim_upstream.sv" "$R/memory/tvram_ddr.sv" "${BOARD[@]}")
  TOP=sim_upstream; DEF=()
fi
echo "3 of 3 build steps: Verilator (some minutes the first time)"
verilator --cc --exe --build -j 4 -O3 --x-assign fast --x-initial unique --noassert \
  -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN -Wno-COMBDLY -Wno-LATCH -Wno-UNOPTFLAT -Wno-INITIALDLY -Wno-PROCASSWIRE -Wno-MULTITOP -Wno-BLKANDNBLK \
  -DPSRAM_LAT_R=${PSRAM_LAT_R:-4} -DPSRAM_LAT_W=${PSRAM_LAT_W:-4} ${SIM_VFLAGS:-} ${DEF[@]+"${DEF[@]}"} \
  --top-module "$TOP" -Mdir "$B/${SIM_OBJ:-obj}" --prefix "V$TOP" \
  -CFLAGS "-std=gnu++20 -O2 ${DEF[*]+${DEF[*]}} -w" -LDFLAGS "-lz" -MAKEFLAGS OPT_FAST=-O3 -MAKEFLAGS OPT_SLOW=-O1 \
  "${SRC[@]}" "$S/main.cpp" > "$B/verilator.log" 2>&1 || { grep -E '%Error' "$B/verilator.log" | head -30; tail -5 "$B/verilator.log"; exit 1; }
cat > "$B/run${SIM_OBJ:+_$SIM_OBJ}" <<EOF2
#!/bin/sh
X68K_SIM_GEN="$B/gen" exec "$B/${SIM_OBJ:-obj}/V$TOP" "\$@"
EOF2
chmod +x "$B/run${SIM_OBJ:+_$SIM_OBJ}"
echo "built: $B/run${SIM_OBJ:+_$SIM_OBJ}"
