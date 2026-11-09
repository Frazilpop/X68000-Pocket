#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The FM bench, jt51 and IKAOPM side by side, into build/sound/opm_bench, and the 48 kHz resampler's; then
#   build/sound/opm_bench/run <writes.txt> <out dir> [seconds]
set -euo pipefail
cd "$(dirname "$0")/../.."
B=$PWD/build/sound/opm_bench
mkdir -p "$B"
verilator --cc --exe --build -j 4 -O3 --x-assign fast --x-initial unique --noassert -Wno-fatal -Wno-lint -Wno-style \
  -Wno-MULTIDRIVEN -Wno-COMBDLY -Wno-LATCH -Wno-UNOPTFLAT -Wno-INITIALDLY -Wno-PROCASSWIRE -Wno-BLKANDNBLK +define+IKAOPM_BUSY_FLAG_ENABLE \
  --top-module tb_opm -Mdir "$B/obj" -CFLAGS "-O2 -w" \
  sim/sound/tb_opm.sv rtl/sound/jt51/*.v rtl/sound/IKAOPM/*.v sim/sound/opm_bench.cpp > "$B/verilator.log" 2>&1 \
  || { grep -E '%Error' "$B/verilator.log" | head -20; exit 1; }
ln -sf obj/Vtb_opm "$B/run"
echo "built: $B/run"
# pocket_audio_resample alone: build/sound/resample_bench/run FILE.s16 STRIDE COL SECONDS OUT.s16 TAPS.hex
I=$PWD/build/sound/resample_bench
mkdir -p "$I"
verilator --cc --exe --build -j 4 -O3 --public-flat-rw -Wno-fatal --top-module pocket_audio_resample -Mdir "$I/obj" -CFLAGS "-O2 -w" \
  -GTAPS="\"$PWD/pocket/src/fpga/core/pocket_audio_poly.hex\"" \
  pocket/src/fpga/core/pocket_audio_resample.sv sim/sound/resample_bench.cpp > "$I/verilator.log" 2>&1 \
  || { grep -E '%Error' "$I/verilator.log" | head -20; exit 1; }
ln -sf obj/Vpocket_audio_resample "$I/run"
echo "built: $I/run"
