#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# The raster copy's handshake under a program's starts and stops at random timings, for a few seeds.
#   sh sim/rcpy/run.sh [rastercopy.vhd] [seeds] [lines]     RC_DEBUG=1 prints each line, KEEP=1 keeps the build
set -eu
cd "$(dirname "$0")/../.."
src=${1:-rtl/rastercopy.vhd}; seeds=${2:-8}; lines=${3:-3000}
B=build/sim_rcpy; mkdir -p "$B"
bash tools/get-ghdl.sh
build/tools/ghdl/bin/ghdl --synth --std=08 -fsynopsys --workdir="$B" -garange=17 -gbrsize=7 --out=verilog "$src" -e rastercopy > "$B/rastercopy.v"
verilator --cc --exe --build -j 4 --top-module tb_rcpy -Wno-fatal -Wno-WIDTH -Wno-PINMISSING -Wno-UNOPTFLAT -Wno-MULTIDRIVEN \
    -Wno-lint -Wno-style --Mdir "$B/obj" "$B/rastercopy.v" sim/psram/altsyncram_lite.v sim/models/psram_model.sv rtl/pocket_mem/pocket_psram_bus.sv \
    rtl/pocket_mem/pocket_vram_cache.sv rtl/pocket_mem/tvram_psram.sv sim/rcpy/tb_rcpy.sv sim/rcpy/tb_rcpy.cpp >/dev/null
fail=0
for s in $(seq 1 "$seeds"); do echo "$s of $seeds seeds"; "$B/obj/Vtb_rcpy" "$s" "$lines" || fail=1; done
[ -n "${KEEP:-}" ] || rm -rf "$B"
exit $fail
