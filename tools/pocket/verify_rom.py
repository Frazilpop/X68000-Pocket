#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# X68000 for the Analogue Pocket
"""Check the game files in build/pocket against what MAME loads and lists.

    python3 -I tools/pocket/verify_rom.py all

  * x68000_boot.rom: its CG ROM and IPL, byte for byte, against the addresses MAME
    runs them at (tools/mame_x68k_regions.lua); the gap in it must be zero.
  * each set's disks: size, and CRC against MAME's list hash/x68k_flop.xml read at
    run time, not the builder's copy of it. A disk off that list is reported by name
    as an ALTERNATE and doesn't fail the check if the builder's table allows it.

Exit status 0 only if everything built is right.
"""

import argparse
import os
import subprocess
import sys
import xml.etree.ElementTree as ET
import zlib

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_rom  # noqa: E402  (the module beside this file)

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LIST = os.path.join(REPO, "third_party", "mame", "hash", "x68k_flop.xml")


def first_diff(a, b):
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            return i
    return None


def verify_boot(romdir, dumpdir, run_mame):
    img = open(os.path.join(romdir, build_rom.BOOT_NAME), "rb").read()
    if len(img) != build_rom.BOOT_SIZE:
        print(f"  boot ROM is {len(img):#x} bytes")
        return False
    if run_mame:
        r = subprocess.run([os.path.join(REPO, "tools", "pocket", "mame_oracle.sh"),
                            os.path.join(REPO, "tools", "mame_x68k_regions.lua"), "none",
                            f"DUMP_DIR={dumpdir}"], capture_output=True, text=True)
        if not os.path.exists(os.path.join(dumpdir, "boot.bin")):
            sys.stdout.write(r.stdout + r.stderr)
            raise SystemExit("MAME did not dump its boot region")
    mame = open(os.path.join(dumpdir, "boot.bin"), "rb").read()
    ok = True
    for name, size, crc, off in (build_rom.CGROM, build_rom.IPLROM):
        d = first_diff(img[off:off + size], mame[off:off + size])
        crc_ok = zlib.crc32(img[off:off + size]) == crc
        print(f"  {name:<11} at {off:#07x}: {'MATCH' if d is None and crc_ok else f'DIFFERS at +{d}'}")
        ok &= d is None and crc_ok
    gap = img[build_rom.CGROM[1]:build_rom.IPLROM[3]]
    if any(gap):
        print("  the gap between them is not zero")
        ok = False
    return ok


def mame_list():
    root = ET.parse(LIST).getroot()
    out = {}
    for s in root.findall("software"):
        out[s.get("name")] = [(int(r.get("size")), int(r.get("crc"), 16))
                              for p in s.findall("part") for r in p.iter("rom")]
    return out


def verify_set(name, romdir, listed):
    ok = True
    _, _, disks = build_rom.SETS[name]
    theirs = listed.get(name, [])
    if len(theirs) != len(disks):
        print(f"{name}: MAME lists {len(theirs)} disks, the builder {len(disks)}")
        return False
    done = 0
    for n, disk in enumerate(disks, 1):
        path = os.path.join(romdir, build_rom.disk_name(name, n))
        if not os.path.exists(path):
            continue
        done += 1
        data = open(path, "rb").read()
        crc = zlib.crc32(data)
        size, want = theirs[n - 1]
        if len(data) == size and crc == want:
            print(f"{name} disk {n}: MATCHES MAME, {crc:08x}")
        elif any(c == crc or (s == build_rom.XDF_SIZE and
                              zlib.crc32(data[256:]) == c) for s, c, _ in disk["alternates"]):
            print(f"{name} disk {n}: ALTERNATE {crc:08x}, MAME lists {want:08x}")
        else:
            print(f"{name} disk {n}: WRONG, {crc:08x}, MAME lists {want:08x}")
            ok = False
    if not done:
        print(f"{name}: not built")
    return ok


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("set", help="set name, comma list, or 'all'")
    ap.add_argument("--romdir", default=os.path.join(REPO, "build", "pocket"))
    ap.add_argument("--dumpdir", default=os.path.join(REPO, "build", "mame", "regions"))
    ap.add_argument("--no-mame", action="store_true", help="reuse the region dump")
    a = ap.parse_args()
    print("boot ROM:")
    ok = verify_boot(a.romdir, a.dumpdir, not a.no_mame)
    listed = mame_list()
    for s in build_rom.expand_sets(a.set):
        ok &= verify_set(s, a.romdir, listed)
    print("OK" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
