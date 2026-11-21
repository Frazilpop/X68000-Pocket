#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# X68000 for the Analogue Pocket — the release zip.
#
#   tools/pocket/release.sh            build/release/x68000-VERSION.zip
#
# One zip with Cores/, Platforms/ and Assets/ at its root, as it goes onto the
# card: pocket/dist/ as git tracks it (no .DS_Store, the platform banner
# included) and the released bitstream, which is refused unless its SHA-256
# is the one below: the bitstream played on the Pocket. It is taken from
# build/release/bitstream.rbf_r, or copied there from pocket/dist/ the first
# time, so a later build cannot change what the release holds. VERSION is
# core.json's. The zip's dates are the commit's, so the same commit makes the
# same zip.
#
# Refused too: changes to pocket/dist/ not committed, a core folder whose name
# isn't core.json's author.shortname exactly (the name the Pocket and the
# openFPGA library look for), and a core.json whose date_release isn't the
# commit's day, or a field over Analogue's limits (31 characters for core.json's
# shortname, author and version and the platform's name, 63 for the
# description). Afterwards the zip is unpacked into an empty folder and held
# against pocket/dist/, file by file. No boot ROM, disk or instance JSON goes
# in: the card's Assets/x68000/common/ is left empty for the player's own.

set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
BITSTREAM_SHA256=f961dd3591fc5e3f09dc85172fa502c84d3314d151bc6bdf3f35ab3f6e946a08
DIST=pocket/dist
OUT="$REPO/build/release"
BIN="$OUT/bitstream.rbf_r"
cd "$REPO"

die() { echo "release: $*" >&2; exit 1; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

[ -z "$(git status --porcelain -- "$DIST")" ] || die "$DIST has changes not committed"
cores=$(git ls-files "$DIST/Cores" | cut -d/ -f4 | sort -u)
[ "$(echo "$cores" | wc -l | tr -d ' ')" = 1 ] || die "expected one core in $DIST/Cores, found: $cores"

mkdir -p "$OUT"
if [ ! -f "$BIN" ]; then
	built="$DIST/Cores/$cores/bitstream.rbf_r"
	[ -f "$built" ] || die "no $BIN and no $built"
	[ "$(sha "$built")" = "$BITSTREAM_SHA256" ] || die "$built is not the released bitstream (SHA-256 $(sha "$built"), expected $BITSTREAM_SHA256)"
	cp "$built" "$BIN"
fi
[ "$(sha "$BIN")" = "$BITSTREAM_SHA256" ] || die "$BIN is not the released bitstream (SHA-256 $(sha "$BIN"), expected $BITSTREAM_SHA256)"

JSON="$DIST/Cores/$cores/core.json"
read -r AUTHOR VERSION DATE SHORT < <(python3 -I -c '
import json, sys
m = json.load(open(sys.argv[1]))["core"]["metadata"]
print(m["author"], m["version"], m["date_release"], m["shortname"])' "$JSON")
[ "$cores" = "$AUTHOR.$SHORT" ] || die "the core folder is $cores but core.json makes it $AUTHOR.$SHORT"
DAY=$(TZ=UTC git log -1 --format=%cd --date=format-local:%Y-%m-%d)
[ "$DATE" = "$DAY" ] || die "core.json's date_release is $DATE, the commit's day $DAY"
long=$(python3 -I -c '
import json, sys, glob
m = json.load(open(sys.argv[1]))["core"]["metadata"]
for k, n in (("shortname", 31), ("author", 31), ("version", 31), ("description", 63)):
    if len(m.get(k, "")) > n: print(f"core.json {k} is {len(m[k])} characters, over {n}")
for f in sorted(glob.glob(sys.argv[2] + "/Platforms/*.json")):
    name = json.load(open(f))["platform"]["name"]
    if len(name) > 31: print(f"{f} name is {len(name)} characters, over 31")' "$JSON" "$DIST")
[ -z "$long" ] || die "$long"

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/x68000-release.XXXXXX")
CHECK=$(mktemp -d "${TMPDIR:-/tmp}/x68000-release-check.XXXXXX")
trap 'rm -rf "$STAGE" "$CHECK"' EXIT

# pocket/dist/ as tracked
git ls-files -z "$DIST" | while IFS= read -r -d '' f; do
	rel=${f#$DIST/}
	case "$(basename "$rel")" in .keep|.DS_Store) continue ;; esac
	mkdir -p "$STAGE/$(dirname "$rel")"
	cp "$f" "$STAGE/$rel"
done
cp "$BIN" "$STAGE/Cores/$cores/bitstream.rbf_r"
mkdir -p "$STAGE/Assets/x68000/common"

STAMP=$(TZ=UTC git log -1 --format=%cd --date=format-local:%Y%m%d%H%M.%S)
find "$STAGE" -exec env TZ=UTC touch -t "$STAMP" {} +
ZIP="$OUT/x68000-$VERSION.zip"
rm -f "$ZIP"
(cd "$STAGE" && find Assets Cores Platforms | LC_ALL=C sort | TZ=UTC zip -X -q "$ZIP" -@)

# a stranger's look: unpacked into an empty folder, held against pocket/dist/
unzip -q "$ZIP" -d "$CHECK"
[ "$(ls "$CHECK" | tr '\n' ' ')" = "Assets Cores Platforms " ] || die "the zip's root is $(ls "$CHECK" | tr '\n' ' ')"
[ -d "$CHECK/Assets/x68000/common" ] || die "the zip has no Assets/x68000/common"
n=0
while IFS= read -r -d '' f; do
	rel=${f#$DIST/}
	case "$(basename "$rel")" in .keep) continue ;; esac
	cmp -s "$f" "$CHECK/$rel" || die "$rel differs from $DIST"
	n=$((n + 1))
done < <(git ls-files -z "$DIST")
cmp -s "$BIN" "$CHECK/Cores/$cores/bitstream.rbf_r" || die "the bitstream differs"
extra=$(cd "$CHECK" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | grep -vxF -f <(git -C "$REPO" ls-files "$DIST" | sed "s|^$DIST/||"; echo "Cores/$cores/bitstream.rbf_r") || true)
[ -z "$extra" ] || die "the zip holds files $DIST doesn't: $extra"

echo "$ZIP"
echo "  $cores $VERSION ($DATE), $((n + 1)) files, the bitstream ${BITSTREAM_SHA256:0:12}"
echo "  SHA-256 $(sha "$ZIP")"
