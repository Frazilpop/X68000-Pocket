#!/bin/bash
# X68000 for the Analogue Pocket — put the core and the game files on the card.
#
#   tools/pocket/deploy.sh [/Volumes/NAME] [--keep]   (--keep is accepted and changes nothing)
#   tools/pocket/deploy.sh --overwrite-disks          replace disks on the card that differ
#   tools/pocket/deploy.sh --status                   is the current build on the card?
#
# Copies pocket/dist ("Cores/frazilpop.X68000" with the bitstream, the
# platform JSON and image, the instance JSONs under Assets/x68000/) onto the
# Pocket's SD card, and from build/pocket (made by tools/pocket/build_rom.py) the
# boot ROM and each target set's disks to Assets/x68000/common/. The card is the
# volume with Analogue_Pocket.json at its root – in the Mac's reader, or the Pocket's
# own over USB. This installs the core itself: nothing has to be on the card first.
#
# A game writes to its disks in the file on the card, so a disk that is there and
# differs from the build is left as it is, and said so. Only --overwrite-disks
# replaces one, and that loses what the game wrote.
#
# The Pocket's card is shared with the other cores' deploy scripts: one
# copies at a time under /tmp/pocket-card.lock. Nothing ejects the card; that is done by hand.
# Each verified copy is recorded in build/pocket/deployed.txt (the bitstream's
# SHA-256, when it was built, the commit, when it was copied).

set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CORE="frazilpop.X68000"
PLATFORM="x68000"
DIST="$REPO/pocket/dist"
BIN="$DIST/Cores/$CORE/bitstream.rbf_r"
ROMS="$REPO/build/pocket"
RECORD="$ROMS/deployed.txt"
SETS="bublbobl salamand gradius chorensa akumajo ffight parodius nemesis sf2ce ssf2"      # the target sets
[ -f "$BIN" ] || { echo "no $BIN - run pocket/build.sh first"; exit 1; }

VOL="" STATUS=0 OVERWRITE=0
for a in "$@"; do
	case "$a" in --keep) ;; --status) STATUS=1 ;; --overwrite-disks) OVERWRITE=1 ;; *) VOL="$a" ;; esac
done

built() { stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$BIN"; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
if [ $STATUS = 1 ]; then
	s=$(sha "$BIN")
	echo "Build:   $(built), SHA-256 ${s:0:12}"
	last=$(sed -n 's/^sha256 //p' "$RECORD" 2>/dev/null || true)
	if [ -z "$last" ]; then
		echo "Card:    no deploy recorded"
	else
		echo "Card:    got the build of $(sed -n 's/^built //p' "$RECORD") at $(sed -n 's/^deployed //p' "$RECORD"), SHA-256 ${last:0:12}"
	fi
	for v in /Volumes/*; do
		[ -f "$v/Analogue_Pocket.json" ] || continue
		f="$v/Cores/$CORE/bitstream.rbf_r"
		[ -f "$f" ] && last=$(sha "$f") || last=none
		echo "         (checked on the mounted card, $v: ${last:0:12})"
	done
	if [ "$last" = "$s" ]; then echo "UP TO DATE - the card has the current build"
	else echo "NOT ON THE CARD - the current build has not been deployed: tools/pocket/deploy.sh"; exit 1; fi
	exit 0
fi

# the sets to copy: every target set that has its first disk and an instance JSON
sets=()
for s in $SETS; do
	[ -f "$ROMS/${s}_1.dim" ] && [ -f "$DIST/Assets/$PLATFORM/$CORE/$s.json" ] && sets+=("$s")
done
[ ${#sets[@]} -gt 0 ] || echo "Warning: no disks in $ROMS - the core goes on without games (tools/pocket/build_rom.py all ~/Downloads build/pocket)"
BOOT="$ROMS/x68000_boot.rom"
[ -f "$BOOT" ] || echo "Warning: no $BOOT - the core will not start without it (tools/pocket/build_rom.py all ~/Downloads build/pocket)"

# A card pulled without being ejected is checked by macOS before it mounts
# again (~2 minutes for a big card): wait for it rather than fail.
find_card() {
	local v
	for v in /Volumes/*; do
		[ -f "$v/Analogue_Pocket.json" ] && { VOL="$v"; return 0; }
	done
	return 1
}
card_being_checked() {
	local d
	for d in $(diskutil list physical | sed -n 's|^/dev/\(disk[0-9]*\) (.*physical.*|\1|p'); do
		[ "$d" = disk0 ] && continue
		diskutil info "${d}s1" 2>/dev/null | grep -qE 'Mounted: +No' && return 0
	done
	return 1
}
if [ -z "$VOL" ]; then
	waited=0
	until find_card; do
		card_being_checked && [ $waited -lt 300 ] || break
		[ $waited = 0 ] && echo "The card is attached but macOS is checking it before mounting it (it was not ejected last time) - about 2 minutes; leave it connected..."
		sleep 2; waited=$((waited + 2))
	done
fi
[ -n "$VOL" ] || { echo "No Analogue Pocket SD card found (no volume with Analogue_Pocket.json)"; exit 1; }

# The lock is taken only once a card is mounted: finding the card only reads
# /Volumes; the copy is what the lock protects. (Taken first, a deploy left
# retrying for a card not in the reader held it, and every other core's
# deploy waited until the card appeared.)
LOCK=/tmp/pocket-card.lock
release() {
	[ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK"
	return 0
}
trap release EXIT
until mkdir "$LOCK" 2>/dev/null; do
	holder=$(cat "$LOCK/pid" 2>/dev/null || true)
	if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then rm -rf "$LOCK"; continue; fi
	[ -n "${told:-}" ] || { echo "Waiting for another deploy to the card (pid ${holder:-?})..."; told=1; }
	sleep 1
done
echo $$ >"$LOCK/pid"

[ -f "$VOL/Analogue_Pocket.json" ] || { echo "$VOL is not the Pocket's card"; exit 1; }

# the core, the platform and the instance JSONs
for d in Cores Platforms Assets; do
	[ -d "$DIST/$d" ] && cp -R "$DIST/$d" "$VOL/"
done
echo "Copied the core ($CORE), the platform and the instance JSONs (${#sets[@]} set(s) with disks)"

# the boot ROM: replaced if it differs, as nothing writes to it
common="$VOL/Assets/$PLATFORM/common"
mkdir -p "$common"
if [ -f "$BOOT" ]; then
	if cmp -s "$BOOT" "$common/x68000_boot.rom"; then
		echo "  x68000_boot.rom already on the card"
	else
		cp "$BOOT" "$common/x68000_boot.rom"
		cmp -s "$BOOT" "$common/x68000_boot.rom" || { echo "copy of x68000_boot.rom differs"; exit 1; }
		echo "  x68000_boot.rom copied"
	fi
fi

# the disks: a missing one is copied, and one that differs is a game's writes unless told otherwise
kept=0
for s in ${sets[@]+"${sets[@]}"}; do
	for f in "$ROMS/${s}"_*.dim; do
		n=$(basename "$f")
		if [ ! -f "$common/$n" ] || { [ $OVERWRITE = 1 ] && ! cmp -s "$f" "$common/$n"; }; then
			cp "$f" "$common/$n"
			cmp -s "$f" "$common/$n" || { echo "copy of $n differs"; exit 1; }
			echo "  $n copied"
		elif cmp -s "$f" "$common/$n"; then
			echo "  $n already on the card"
		else
			echo "  $n KEPT: the one on the card differs from the build, as a game's writes would"
			kept=$((kept + 1))
		fi
	done
done
[ $kept = 0 ] || echo "$kept disk(s) left as they were on the card; --overwrite-disks replaces them and loses what was written"

# the test entries from tools/pocket/make_test_disk.py: on the card while build/pocket/test is there, and
# taken off once it's gone. The self test's disk goes on only when missing, as it counts its own launches.
TESTS="$ROMS/test"
inst="$VOL/Assets/$PLATFORM/$CORE"
if [ -d "$TESTS" ]; then
	for f in "$TESTS"/*.json; do cp "$f" "$inst/"; done
	for f in "$TESTS"/*.dim; do
		n=$(basename "$f")
		if [ -f "$common/$n" ]; then echo "  $n already on the card (kept, with its count)"
		else cp "$f" "$common/$n"; cmp -s "$f" "$common/$n" || { echo "copy of $n differs"; exit 1; }; echo "  $n copied"; fi
	done
	echo "Test entries on the card: $(cd "$TESTS" && ls *.json | sed 's/\.json$//' | tr '\n' ' ')"
else
	for n in selftest memtest noboot; do
		if [ -f "$inst/$n.json" ]; then rm "$inst/$n.json"; echo "  test entry $n taken off"; fi
	done
	for n in selftest_1.dim memtest_1.dim; do
		if [ -f "$common/$n" ]; then rm "$common/$n"; fi
	done
fi

# drop the ._ AppleDouble files macOS writes beside them on a FAT card
for d in "$VOL/Cores/$CORE" "$VOL/Platforms" "$VOL/Assets/$PLATFORM"; do
	dot_clean -m "$d" 2>/dev/null || true
done

a=$(sha "$BIN") b=$(sha "$VOL/Cores/$CORE/bitstream.rbf_r")
[ "$a" = "$b" ] || { echo "the bitstream on the card differs from the build"; exit 1; }
mkdir -p "$ROMS"
printf 'sha256 %s\nbuilt %s\ncommit %s\ndeployed %s\n' "$a" "$(built)" \
	"$(git -C "$REPO" log -1 --format=%h 2>/dev/null)" "$(date '+%Y-%m-%d %H:%M')" >"$RECORD"
echo "Bitstream SHA-256 verified on the card: the build of $(built) is on $VOL"
category=$(sed -n 's/.*"category": *"\([^"]*\)".*/\1/p' "$DIST/Platforms/$PLATFORM.json")
echo "Left $VOL mounted - eject it yourself, then back in the Pocket and launch: openFPGA > $category > X68000"
