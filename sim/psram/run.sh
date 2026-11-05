#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds and runs the VRAM ports against their chips' models, at each latency the part might show.
set -eu
cd "$(dirname "$0")/../.."
for lat in "4 4" "3 4" "5 3"; do
    set -- $lat
    obj=build/sim_psram/obj_$1_$2; mkdir -p "$obj"
    verilator --cc --exe --build -j 4 --top-module tb_vram -Wno-fatal -Wno-WIDTH -Wno-PINMISSING -Wno-UNOPTFLAT -Wno-MULTIDRIVEN \
        -GLAT_R=$1 -GLAT_W=$2 --Mdir "$obj" \
        sim/psram/altsyncram_lite.v sim/models/psram_model.sv rtl/pocket_mem/pocket_psram_bus.sv \
        rtl/pocket_mem/pocket_vram_cache.sv rtl/pocket_mem/gvram_psram.sv rtl/pocket_mem/tvram_psram.sv \
        sim/psram/tb_vram.sv sim/psram/tb_vram.cpp >/dev/null
    echo "== the part's read latency $1, write latency $2"
    "$obj/Vtb_vram"
done
rm -rf build/sim_psram
