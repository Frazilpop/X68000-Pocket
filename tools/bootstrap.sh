#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Fetches what this core reads and builds with into third_party/, gitignored and never
# committed, and GHDL into build/tools/ghdl. The core's own RTL is already in rtl/.
#
#   tools/bootstrap.sh              fetch at the pins in deps.lock
#   tools/bootstrap.sh --no-mame    skip the MAME sparse checkout
#   tools/bootstrap.sh --update     move every pin to its branch's current head
#
# A clone already there is kept: its revision is checked against the pin, and a difference is a
# warning, never a change. So a clone with its full history is as good as a shallow one.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/third_party"
LOCK="$ROOT/deps.lock"

DO_MAME=1
DO_UPDATE=0
for a in "$@"; do
  case "$a" in
    --no-mame) DO_MAME=0 ;;
    --update)  DO_UPDATE=1 ;;
    -h|--help) sed -n '4,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 1 ;;
  esac
done

# name | repo | branch | role
#
# x68000-mister: the upstream of rtl/, read for its fixes and for what it left out, and the
# second reference in simulation. Its releases/ folder holds boot.rom and boot3.vhd, Sharp's
# ROMs and an image: nothing from there ever comes into this repo.
#
# fx68k: rtl/FX68K is upstream's copy, and is what synthesis reads. Simulation reads
# hdl/verilator here, a variant flattening the s_nanod struct that Verilator cannot take.
DEPS=(
  "x68000-mister|MiSTer-devel/X68000_MiSTer|master|upstream of rtl/, second reference"
  "fx68k|jtfpga/fx68k|master|68000 for simulation"
)

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
pin()  { git -C "$1" rev-parse HEAD 2>/dev/null || echo UNKNOWN; }

pinned_sha() { # name -> the revision in deps.lock, empty if none
  [ -f "$LOCK" ] || return 0
  awk -v n="$1" '$1 == n { print $3 }' "$LOCK"
}

# Move a fresh clone onto its pin. GitHub allows fetching a reachable revision by itself, so
# this stays shallow.
checkout_pin() { # name dir
  local name="$1" dir="$2" want
  if [ "$DO_UPDATE" = 1 ]; then return 0; fi
  want="$(pinned_sha "$name")"
  if [ -z "$want" ] || [ "$want" = UNKNOWN ]; then return 0; fi
  if [ "$(pin "$dir")" = "$want" ]; then return 0; fi
  if git -C "$dir" fetch --depth 1 -q origin "$want" 2>/dev/null; then
    git -C "$dir" checkout -q FETCH_HEAD
    echo "  $name: pinned to $want"
  else
    warn "  $name: pin $want not fetchable, left at $(pin "$dir")"
  fi
}

check_pin() { # name dir: a clone already there
  local name="$1" dir="$2" want
  want="$(pinned_sha "$name")"
  if [ -n "$want" ] && [ "$want" != UNKNOWN ] && [ "$(pin "$dir")" != "$want" ]; then
    warn "  $name: on disk $(pin "$dir"), deps.lock says $want"
  fi
}

say "== toolchain"
have git || die "missing: git"
for t in verilator mame 7zz; do
  if have "$t"; then echo "  $t  $(command -v "$t")"; else warn "  $t  MISSING"; fi
done
# pocket/build.sh runs Quartus 21.1 Lite in Docker (raetro/quartus:21.1, linux/amd64) on Colima.
if have docker && docker info >/dev/null 2>&1; then
  echo "  docker  $(command -v docker)"
else
  warn "  docker  MISSING or not running: the build needs it"
fi
echo

mkdir -p "$VENDOR"
TMP="$LOCK.tmp"
{
  echo "# Pinned revisions. Regenerate with tools/bootstrap.sh --update"
} > "$TMP"

say "== dependencies"
for entry in "${DEPS[@]}"; do
  IFS='|' read -r name repo branch role <<< "$entry"
  dest="$VENDOR/$name"
  if [ -d "$dest/.git" ]; then
    if [ "$DO_UPDATE" = 1 ]; then
      echo "  $name: updating"
      git -C "$dest" fetch -q origin "$branch"
      git -C "$dest" checkout -q FETCH_HEAD
    else
      echo "  $name: present"
      check_pin "$name" "$dest"
    fi
  else
    echo "  $name: cloning $repo ($role)"
    git clone --depth 1 --branch "$branch" -q "https://github.com/$repo.git" "$dest"
    checkout_pin "$name" "$dest"
  fi
  printf '%-14s %s %s\n' "$name" "$repo" "$(pin "$dest")" >> "$TMP"
done

# MAME is enormous: a blobless clone and a sparse checkout take only the files read here, a few
# MB. x68k_flop.xml is the software list build_rom.py and the census check the disks against.
if [ "$DO_MAME" = 1 ]; then
  echo
  say "== mame (sparse)"
  dest="$VENDOR/mame"
  if [ -d "$dest/.git" ]; then
    echo "  present"
    check_pin mame "$dest"
  else
    git clone --filter=blob:none --no-checkout --depth 1 -q https://github.com/mamedev/mame.git "$dest"
    git -C "$dest" sparse-checkout init --no-cone
    git -C "$dest" sparse-checkout set \
      '/src/mame/sharp/x68k*' \
      '/hash/x68k_flop.xml' \
      '/src/devices/machine/hd63450*' \
      '/src/devices/sound/okim6258*' \
      '/src/devices/machine/mc68901*'
    # Only now the pin: the clone is --no-checkout, and checking out before the sparse patterns
    # exist would fetch every blob.
    checkout_pin mame "$dest"
    git -C "$dest" checkout -q
  fi
  printf '%-14s %s %s\n' mame mamedev/mame "$(pin "$dest")" >> "$TMP"
elif [ -n "$(pinned_sha mame)" ]; then
  printf '%-14s %s %s\n' mame mamedev/mame "$(pinned_sha mame)" >> "$TMP"
fi

echo
say "== ghdl"
bash "$ROOT/tools/get-ghdl.sh"
ghdl_version="$(cat "$ROOT/build/tools/ghdl/VERSION" 2>/dev/null || echo UNKNOWN)"
printf '%-14s %s %s\n' ghdl ghdl/ghdl "v$ghdl_version" >> "$TMP"
echo "  $ghdl_version in build/tools/ghdl"

mv "$TMP" "$LOCK"

# fx68k reads its microcode with $readmemb at run time, relative to the working directory, and
# all-X microcode looks like a CPU that fetches once and stops.
if [ -f "$VENDOR/fx68k/hdl/microrom.mem" ]; then
  ln -sf third_party/fx68k/hdl/microrom.mem "$ROOT/microrom.mem"
  ln -sf third_party/fx68k/hdl/nanorom.mem  "$ROOT/nanorom.mem"
fi

cat <<'REPORT'

Licences of what is now in third_party/ (rtl/ has its own, in its files and in LICENSE):
  x68000-mister  GPL-3.0, added as LICENSE upstream on 2 Nov 2026 with Puu-san's agreement. Its
                 VHDL carries no headers. Never copy from its releases/: those are Sharp's ROMs.
  fx68k          GPL-3.0-only: a bare GPLv3 with no "or later" grant from Jorge Cwik.
  mame           Mixed: read the header of each file. MAME as a whole is GPL-2.0.
REPORT
