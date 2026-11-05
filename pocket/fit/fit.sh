#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Fits X68K_top alone on the Pocket's part in build/fit_cut, with no shell: what the cuts in rtl/
# leave. Quartus 21.1 Lite in Docker on Colima, about 20 minutes, one processor.
#
#   sh pocket/fit/fit.sh           synthesis, fitter and timing
#   sh pocket/fit/fit.sh --map     synthesis only, about 5 minutes
#
# A project of its own, as init files are named relative to the project's folder (rtl/...).
# Prints each stage; Quartus's output goes to build/fit_cut/compile.log.
set -eu
cd "$(dirname "$0")/../.."
root=$(pwd -P)
image=raetro/quartus:21.1
dir=build/fit_cut
map_only=0
[ "${1:-}" = "--map" ] && map_only=1

colima status >/dev/null 2>&1 || colima start >/dev/null 2>&1 || { echo "Colima would not start"; exit 1; }

# Colima holds three compiles at once, counting other projects' builds.
while [ "$(docker ps --format '{{.Image}}' | grep -c quartus || true)" -ge 3 ]; do
    echo "waiting: three Quartus compiles running"
    sleep 60
done

mkdir -p "$dir"
rm -rf "$dir/rtl"
cp -R rtl "$dir/rtl"
cp pocket/fit/x68k_cut.qpf pocket/fit/x68k_cut.qsf pocket/fit/x68k_cut.sdc "$dir/"
log=$dir/compile.log
: > "$log"
start=$(date +%s)
run() { # n label cmd...
    n=$1; label=$2; shift 2
    stages=3; [ $map_only = 1 ] && stages=1
    echo "$n of $stages: $label ($(( $(date +%s) - start )) s so far)"
    docker run --rm --platform linux/amd64 -v "$root":/build -w "/build/$dir" "$image" "$@" >> "$log" 2>&1
}
rc=0
run 1 synthesis quartus_map --read_settings_files=on --write_settings_files=off x68k_cut -c x68k_cut || rc=1
if [ $rc = 0 ] && [ $map_only = 0 ]; then
    run 2 fitter quartus_fit --read_settings_files=off --write_settings_files=off x68k_cut -c x68k_cut || rc=2
    if [ $rc = 0 ]; then run 3 timing quartus_sta x68k_cut -c x68k_cut || rc=3; fi
fi
echo "finished rc=$rc after $(( $(date +%s) - start )) s"
exit $rc
