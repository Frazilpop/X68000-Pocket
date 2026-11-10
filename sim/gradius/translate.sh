#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The board's VHDL in Verilog through GHDL, into build/sim/<which>/gen. Again only if a source changed.
#   sim/gradius/translate.sh port        rtl/, this tree
#   sim/gradius/translate.sh upstream    third_party/x68000-mister/rtl, at the pin in deps.lock
set -euo pipefail
cd "$(dirname "$0")/../.."
which=$1
case "$which" in
  port) R=$PWD/rtl; G_ARGS=() ;;
  upstream) R=$PWD/third_party/x68000-mister/rtl; G_ARGS=() ;;
  *) echo "port or upstream"; exit 1 ;;
esac
S=$PWD/sim/gradius
B=$PWD/build/sim/$which/gen
GHDL=$PWD/build/tools/ghdl/bin/ghdl
bash tools/get-ghdl.sh
KEY=$(find "$R" -name '*.vhd' -print0 | sort -z | xargs -0 cat | cat - "$S/translate.py" "$S/translate.sh" "$S/altera_mf.vhd" | shasum | cut -c1-16)
if [ "$(cat "$B/key" 2>/dev/null)" = "$KEY" ]; then exit 0; fi
echo "Translating the board from VHDL ($which)"
rm -rf "$B"; mkdir -p "$B/altera_mf" "$B/work" "$B/vhd"
python3 -I "$S/translate.py" copy "$R" "$B/vhd"
python3 -I "$S/translate.py" inits "$R" "$B"
A=(--std=08 -frelaxed -fsynopsys -fexplicit -Wno-hide -Wno-binding -Wno-nowrite)
"$GHDL" -a "${A[@]}" --work=altera_mf --workdir="$B/altera_mf" "$S/altera_mf.vhd"
W=(--workdir="$B/work" -P"$B/altera_mf")
cd "$B/vhd"
PK=$(grep -rliE '^\s*package\s' . --include='*.vhd' || true)
for f in $PK; do "$GHDL" -a "${A[@]}" "${W[@]}" "$f"; done
LOG=$B/ghdl.log; : > "$LOG"
# Upstream's D88 path: GHDL won't take it, and with disk_mode high nothing reads it. Left as empty modules.
SKIP='IKAOPM'; [ "$which" = upstream ] && SKIP='IKAOPM|/FDC/FDCs.vhd|/diskemu/diskemu.vhd'
for f in $(find . -name '*.vhd' | grep -vE "$SKIP" | sort); do
  echo "$PK" | grep -qxF "$f" && continue
  "$GHDL" -a "${A[@]}" "${W[@]}" "$f" >> "$LOG" 2>&1 || echo "not analysed: $f" >> "$LOG"
done
cd "$B"
"$GHDL" --synth --latches "${A[@]}" "${W[@]}" --out=verilog x68k_top > raw.v 2>> "$LOG" || { grep -i error "$LOG" | tail -20; exit 1; }
# A latch GHDL writes as always @(enable) never follows its input in Verilator (the Genesis core's lesson).
if grep -nE 'always @\(n[0-9]+\)' raw.v; then echo "A latch in the translation that won't work in Verilator"; exit 1; fi
python3 -I "$S/translate.py" wrap raw.v "$R/X68K_top.vhd" > x68k_top.sv
python3 -I "$S/translate.py" stubs raw.v "$R/X68K_top.vhd" "$which" >> x68k_top.sv
echo "$KEY" > key
wc -l x68k_top.sv
