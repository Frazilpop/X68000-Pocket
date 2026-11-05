#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Run one of the tools/mame_x68k_*.lua oracle scripts on one game, reproducibly.
#
#   tools/pocket/mame_oracle.sh <script.lua> <set> [VAR=value ...] [-- mame args]
#
#   tools/pocket/mame_oracle.sh tools/mame_x68k_census.lua bublbobl \
#       CENSUS_OUT=build/mame/census/bublbobl.log CENSUS_FRAMES=9000
#   tools/pocket/mame_oracle.sh tools/mame_x68k_bus_trace.lua none \
#       BUS_TRACE_OUT=build/mame/ipl_bus.txt BUS_TRACE_COUNT=200000
#
# <set> names the disks build/pocket/<set>_<n>.dim; "none" runs with an empty drive.
# The first two disks go in drives 0 and 1, as the core's start does. Plan files
# can load the others, by name.
#
# What it fixes, every run:
#   * the machine: x68000 at IPL 1.0, from a ROM folder cut out of
#     build/pocket/x68000_boot.rom (the default BIOS isn't the one on hand);
#   * fresh, empty cfg and nvram directories under build/, so no setting or SRAM
#     leaks between runs;
#   * COPIES of the disks in that run's directory, as a game may write to them and
#     the images are the ones that go on the card;
#   * -skip_gameinfo -autoboot_delay 0: the script goes on before the CPU has run.
# SRAM_SEED=1 starts its SRAM as the core's does, from rtl/diskemu/sramdefault.hex, rather than
# MAME's blank: otherwise the IPL takes another path from its first look at it.
# Relative paths in VAR=value are made absolute (the scripts run with MAME's own
# working directory).

set -eu
[ $# -ge 2 ] || { sed -n '3,13p' "$0"; exit 2; }
script=$1; set_name=$2; shift 2

repo=$(cd "$(dirname "$0")/../.." && pwd)
case $script in /*) ;; *) script=$PWD/$script ;; esac

while [ $# -gt 0 ] && [ "$1" != "--" ]; do
  case $1 in
    *=/*|*=) export "$1" ;;
    *_DIR=*|*_OUT=*|PLAN=*) k=${1%%=*}; v=${1#*=}; export "$k=$PWD/$v" ;;
    *=*) export "$1" ;;
    *) echo "mame_oracle.sh: expected VAR=value, got '$1'" >&2; exit 2 ;;
  esac
  shift
done
[ "${1:-}" = "--" ] && shift

boot=$repo/build/pocket/x68000_boot.rom
[ -f "$boot" ] || { echo "no $boot: run tools/pocket/build_rom.py first" >&2; exit 1; }

mkdir -p "$repo/build/mame/run"
run=$(mktemp -d "$repo/build/mame/run/$set_name.XXXXXX")
trap 'rm -r "$run"' EXIT
mkdir -p "$run/cfg" "$run/nvram" "$run/snap" "$run/roms/x68000"
dd if="$boot" of="$run/roms/x68000/cgrom.dat" bs=65536 count=12 2>/dev/null
dd if="$boot" of="$run/roms/x68000/iplrom.dat" bs=65536 skip=14 count=2 2>/dev/null

if [ -n "${SRAM_SEED:-}" ]; then
  mkdir -p "$run/nvram/x68000_0"
  python3 -I - "$repo/rtl/diskemu/sramdefault.hex" "$run/nvram/x68000_0/nvram" <<'PY'
import sys
words = {}
for line in open(sys.argv[1]):
    line = line.strip()
    if line.startswith(':'):
        b = bytes.fromhex(line[1:])
        if b[3] == 0:
            words[(b[1] << 8) | b[2]] = bytes(b[4:6])
# MAME keeps the machine's words as host words: on this Mac, the low byte first, which is as the
# hex file has them
open(sys.argv[2], 'wb').write(b''.join(words.get(i, b'\0\0') for i in range(8192)))
PY
fi

flops=
if [ "$set_name" != none ]; then
  n=1
  for f in "$repo/build/pocket/$set_name"_*.dim; do
    [ -f "$f" ] || { echo "no disks for $set_name in build/pocket" >&2; exit 1; }
    cp "$f" "$run/"
    if [ $n -le 2 ]; then flops="$flops -flop$n $run/$(basename "$f")"; fi
    n=$((n + 1))
  done
fi
export DISK_DIR="$run"

start=$(date +%s)
# shellcheck disable=SC2086
(cd "$run" && "${MAME:-mame}" x68000 -bios ipl10 -rompath "$run/roms" $flops \
  -autoboot_script "$script" -skip_gameinfo -autoboot_delay 0 \
  -video none -sound none -nothrottle -seconds_to_run 7200 \
  -cfg_directory "$run/cfg" -nvram_directory "$run/nvram" \
  -snapshot_directory "$run/snap" "$@")
echo "mame_oracle.sh: $set_name finished in $(( $(date +%s) - start )) s"
