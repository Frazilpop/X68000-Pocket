#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# X68000 for the Analogue Pocket
"""Build the Pocket's game files for the X68000 from the images in a folder.

    python3 -I tools/pocket/build_rom.py all ~/Downloads build/pocket
    python3 -I tools/pocket/build_rom.py bublbobl,sf2ce ~/Downloads build/pocket

Writes OUTDIR/x68000_boot.rom, once, and OUTDIR/<set>_<n>.dim for each disk of
each set. A folder with no game files in it is an error for that set only, so
a card can carry the games on hand.

THE BOOT ROM is 1 MB loaded through the bridge at offset 0, and it lands at
F00000 of the machine: CG ROM (cgrom.dat, 0xC0000), then 0x20000 zeros for the
SCSI ROM this model hasn't got, then IPL 1.0 (iplrom.dat, 0x20000). Those CRCs
are MAME's x68000 -bios ipl10.

A DISK is a DIM as MAME's software list x68k_flop has it: 1,261,824 bytes, a
256-byte header and then 77 tracks a side of 8 sectors of 1024 bytes. The core
reads it from the file on the card in place and a game may write to it, so
tools/pocket/deploy.sh doesn't overwrite one that is already there.

FILES ARE FOUND BY CRC32 AND SIZE, NOT BY NAME OR PATH. Looked through, in this
order, each only if something is still missing:

  * files directly in the folder, and members of the zips in it;
  * zips inside those zips (a collection of game zips, say);
  * .7z archives in the folder or inside a zip there, through 7zz.

A set may be right three ways, and the output says which one each disk took:

  MAME       the CRC in MAME's list.
  rebuilt    an XDF (the same disk with no header) under the standard header
             comes to MAME's CRC, checked after building.
  ALTERNATE  no image on hand has MAME's CRC, and the table names another
             dump. It is not the disk MAME lists: said loudly, with its own
             CRC, and the set still builds.

Nothing else is accepted, whatever a file is called.
"""

import argparse
import hashlib
import io
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile
import zlib

BOOT_NAME = "x68000_boot.rom"
BOOT_SIZE = 0x100000
CGROM = ("cgrom.dat", 0x0C0000, 0x9f3195f1, 0x00000)
IPLROM = ("iplrom.dat", 0x020000, 0x72bdf532, 0xE0000)

DIM_SIZE = 1261824
XDF_SIZE = 1261568

# The commonest DIM header by far (2,378 of the images in one collection of 1,194
# games): type 0 (2HD, 8 sectors), 154 tracks present, the signature, no comment.
DIM_HEADER = (bytes([0]) + bytes([1]) * 154 + bytes(16) + b"DIFC HEADER  " +
              bytes(70) + bytes([0x16, 0x00]))
assert len(DIM_HEADER) == 256


def D(crc, xdf=None, alternates=()):
    """One disk: MAME's CRC, the CRC of an XDF known to rebuild to it, and any
    (size, crc, what) alternates in order of preference."""
    return {"crc": crc, "xdf": xdf, "alternates": alternates}


# MAME's hash/x68k_flop.xml; the alternates and XDF CRCs are from the images
# compared against it. Status is MAME's supported flag: "partial" sets are
# ones its own list says don't run right.
SETS = {
    "bublbobl": ("Bubble Bobble", "full", [D(0x2d4e07b3)]),
    "salamand": ("Salamander", "full", [D(0x149c7bd4)]),
    "gradius": ("Gradius", "full", [
        # The XDF boots straight into the game. The [a] DIM boots to the Visual
        # Shell and needs a mouse to start it.
        D(0x6d17de2a, alternates=(
            (XDF_SIZE, 0xd3820595, "Gradius (1987) (Konami-SPS), an XDF"),
            (DIM_SIZE, 0x68099783, "Gradius (1987)(Sharp - SPS)[a]"),
        ))]),
    "chorensa": ("Chourensha 68k v1.01", "full", [D(0x629efd13)]),
    "akumajo": ("Akumajou Dracula", "full", [D(0x12ed7cbc), D(0x78490385)]),
    "ffight": ("Final Fight", "full", [D(0xd5f1b939), D(0x2c3547c3)]),
    "parodius": ("Parodius Da!", "full", [D(0x534d190b), D(0xc060b794)]),
    "nemesis": ("Nemesis '90 Kai", "partial", [
        D(0x2545199c, alternates=(
            (DIM_SIZE, 0xc2c1dea8, "Nemesis '90 Kai (Disk 1 of 2)(System), unmarked"),
            (DIM_SIZE, 0x9340536a, "Nemesis '90 Kai (Disk 1 of 2)(System)[a3]"),
        )),
        D(0x47b6a39a)]),
    "sf2ce": ("Street Fighter II' Champion Edition", "full",
              [D(0xb93b15e4), D(0x6c750c15), D(0x11e91542), D(0xe37c38c8)]),
    "ssf2": ("Super Street Fighter II", "partial", [
        # The first XDFs come to MAME's CRCs under the standard header. The second are a
        # different dump, seen in a .7z; not run.
        D(0xcd4358eb, xdf=0x5eacf67f, alternates=((XDF_SIZE, 0x28b49fa5, "SYSTEM.XDF"),)),
        D(0xf85c98ff, xdf=0x6bb3366b, alternates=((XDF_SIZE, 0xc4dcbccf, "DISK_1.XDF"),)),
        D(0xbc25b52d, xdf=0x2fca1bb9, alternates=((XDF_SIZE, 0x7e22ce51, "DISK_2.XDF"),)),
        D(0x070d1a9e, xdf=0x94e2b40a, alternates=((XDF_SIZE, 0xc72dd8ec, "DISK_3.XDF"),)),
        D(0x781fa75e, xdf=0xebf009ca, alternates=((XDF_SIZE, 0x2a724cea, "DISK_4.XDF"),)),
        D(0xcb6f1156, xdf=0x5880bfc2, alternates=((XDF_SIZE, 0x527bed62, "DISK_5.XDF"),)),
        D(0xbbbca705, xdf=0x28530991, alternates=((XDF_SIZE, 0xd261827c, "DISK_6.XDF"),))]),
}


def disk_name(setname, n):
    return f"{setname}_{n}.dim"


# ---------------------------------------------------------------------- index
class Index:
    """Every candidate image under a folder, keyed by (size, crc32).

    Each stage only runs when something is still missing, so a folder that
    holds the games loose never opens a 1.7 GB collection.
    """

    WANTED = {DIM_SIZE, XDF_SIZE, CGROM[1], IPLROM[1]}

    def __init__(self, folder):
        self.folder = folder
        self.entries = {}          # (size, crc) -> reader, returning the bytes
        self.nested_done = False
        self.sevenz_done = False
        self.tmp = None
        self.outer_zips = []
        self._scan_top()

    def close(self):
        if self.tmp:
            shutil.rmtree(self.tmp, ignore_errors=True)

    def _add(self, size, crc, reader, where):
        self.entries.setdefault((size, crc), (reader, where))

    def _scan_top(self):
        for name in sorted(os.listdir(self.folder)):
            path = os.path.join(self.folder, name)
            if not os.path.isfile(path):
                continue
            size = os.path.getsize(path)
            if name.lower().endswith(".zip"):
                try:
                    zf = zipfile.ZipFile(path)
                except (zipfile.BadZipFile, OSError):
                    continue
                self.outer_zips.append(path)
                for i in zf.infolist():
                    if not i.is_dir() and i.file_size in self.WANTED:
                        self._add(i.file_size, i.CRC, self._zip_reader(path, i.filename),
                                  f"{name}: {i.filename}")
                zf.close()
            elif size in self.WANTED:
                with open(path, "rb") as f:
                    crc = zlib.crc32(f.read())
                self._add(size, crc, self._file_reader(path), name)

    @staticmethod
    def _file_reader(path):
        def read():
            with open(path, "rb") as f:
                return f.read()
        return read

    @staticmethod
    def _zip_reader(path, member):
        def read():
            with zipfile.ZipFile(path) as zf:
                return zf.read(member)     # zipfile checks the CRC as it reads
        return read

    def _scan_nested(self):
        self.nested_done = True
        for path in self.outer_zips:
            with zipfile.ZipFile(path) as zf:
                for i in zf.infolist():
                    if not i.filename.lower().endswith(".zip"):
                        continue
                    try:
                        inner = zipfile.ZipFile(io.BytesIO(zf.read(i)))
                    except (zipfile.BadZipFile, OSError):
                        continue
                    for j in inner.infolist():
                        if not j.is_dir() and j.file_size in self.WANTED:
                            self._add(j.file_size, j.CRC,
                                      self._nested_reader(path, i.filename, j.filename),
                                      f"{os.path.basename(path)}: {i.filename}: {j.filename}")

    @staticmethod
    def _nested_reader(path, outer, member):
        def read():
            with zipfile.ZipFile(path) as zf:
                with zipfile.ZipFile(io.BytesIO(zf.read(outer))) as inner:
                    return inner.read(member)
        return read

    def _scan_7z(self):
        self.sevenz_done = True
        tool = shutil.which("7zz")
        archives = []
        self.tmp = tempfile.mkdtemp(prefix="x68000_7z_")
        for name in sorted(os.listdir(self.folder)):
            if name.lower().endswith(".7z"):
                archives.append((os.path.join(self.folder, name), name))
        for path in self.outer_zips:
            with zipfile.ZipFile(path) as zf:
                for i in zf.infolist():
                    if i.filename.lower().endswith(".7z"):
                        out = os.path.join(self.tmp, f"a{len(archives)}.7z")
                        with open(out, "wb") as f:
                            f.write(zf.read(i))
                        archives.append((out, f"{os.path.basename(path)}: {i.filename}"))
        if archives and not tool:
            print("  note: .7z archives here, but no 7zz to read them with (brew install sevenzip)")
            return
        for path, where in archives:
            r = subprocess.run([tool, "l", "-slt", path], capture_output=True, text=True,
                               cwd=self.tmp, errors="replace")
            name = size = crc = None
            for line in r.stdout.splitlines() + [""]:
                if line.startswith("Path = "):
                    name = line[7:]
                elif line.startswith("Size = "):
                    size = int(line[7:] or 0)
                elif line.startswith("CRC = ") and line[6:].strip():
                    crc = int(line[6:], 16)
                elif not line.strip():
                    if name and size in self.WANTED and crc is not None:
                        self._add(size, crc, self._7z_reader(tool, path, name, self.tmp),
                                  f"{where}: {name}")
                    name = size = crc = None

    @staticmethod
    def _7z_reader(tool, archive, member, cwd):
        def read():
            r = subprocess.run([tool, "e", "-so", archive, member], capture_output=True, cwd=cwd)
            if r.returncode:
                raise SystemExit(f"7zz could not read {member} from {archive}")
            return r.stdout
        return read

    def find(self, size, crc):
        """(bytes, where), or None. Widens the search only as far as it takes."""
        key = (size, crc)
        if key not in self.entries and not self.nested_done:
            self._scan_nested()
        if key not in self.entries and not self.sevenz_done:
            self._scan_7z()
        hit = self.entries.get(key)
        if hit is None:
            return None
        reader, where = hit
        data = reader()
        if len(data) != size or zlib.crc32(data) != crc:
            raise SystemExit(f"{where} does not match its CRC {crc:08x}")
        return data, where


# ---------------------------------------------------------------------- build
def build_boot(index, outdir):
    img = bytearray(BOOT_SIZE)
    for name, size, crc, offset in (CGROM, IPLROM):
        hit = index.find(size, crc)
        if hit is None:
            raise SystemExit(f"missing {name} (size {size:#x}, crc {crc:08x}) in {index.folder}")
        img[offset:offset + size] = hit[0]
        print(f"    {offset:#07x} {name:<11} {crc:08x} <- {hit[1]}")
    path = os.path.join(outdir, BOOT_NAME)
    with open(path, "wb") as f:
        f.write(img)
    print(f"  {path}  {len(img)} bytes  sha1 {hashlib.sha1(img).hexdigest()}")


def with_header(xdf):
    return DIM_HEADER + xdf


def find_disk(index, disk):
    """(bytes, how, where), or None if no accepted image is here."""
    hit = index.find(DIM_SIZE, disk["crc"])
    if hit:
        return hit[0], "MAME", hit[1]
    if disk["xdf"] is not None:
        hit = index.find(XDF_SIZE, disk["xdf"])
        if hit:
            data = with_header(hit[0])
            if zlib.crc32(data) != disk["crc"]:
                raise SystemExit(f"{hit[1]} under the standard header is "
                                 f"{zlib.crc32(data):08x}, not MAME's {disk['crc']:08x}")
            return data, "rebuilt", hit[1]
    for size, crc, what in disk["alternates"]:
        hit = index.find(size, crc)
        if hit:
            data = hit[0] if size == DIM_SIZE else with_header(hit[0])
            return data, "ALTERNATE", f"{what}, {crc:08x}: {hit[1]}"
    return None


def build_set(setname, index, outdir):
    title, status, disks = SETS[setname]
    found = []
    for n, disk in enumerate(disks, 1):
        got = find_disk(index, disk)
        if got is None:
            print(f"{setname}: {title}: SKIPPED, disk {n} (crc {disk['crc']:08x}) is not "
                  f"in {index.folder}")
            return "missing"
        found.append(got)
    note = "" if status == "full" else f", MAME: {status}"
    print(f"{setname}: {title}, {len(disks)} disk{'s' if len(disks) > 1 else ''}{note}")
    alternates = 0
    for n, (data, how, where) in enumerate(found, 1):
        path = os.path.join(outdir, disk_name(setname, n))
        with open(path, "wb") as f:
            f.write(data)
        if how == "ALTERNATE":
            alternates += 1
            print(f"  !!! ALTERNATE: disk {n} IS NOT THE DISK MAME LISTS "
                  f"(MAME has {disks[n - 1]['crc']:08x}, none on hand)")
        print(f"  {path}  {how:<9} {zlib.crc32(data):08x} <- {where}")
    return "alternate" if alternates else "ok"


def expand_sets(arg):
    if arg == "all":
        return list(SETS)
    names = arg.split(",")
    for n in names:
        if n not in SETS:
            raise SystemExit(f"unknown set {n!r}; known: {', '.join(SETS)}")
    return names


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("set", help="set name, comma list, or 'all'")
    ap.add_argument("zipdir", help="the folder holding the zips")
    ap.add_argument("outdir", help="output directory (keep it under build/)")
    a = ap.parse_args()

    index = Index(os.path.expanduser(a.zipdir))
    os.makedirs(a.outdir, exist_ok=True)
    try:
        print("boot ROM:")
        build_boot(index, a.outdir)
        results = {s: build_set(s, index, a.outdir) for s in expand_sets(a.set)}
    finally:
        index.close()
    built = [s for s, r in results.items() if r != "missing"]
    print(f"{len(built)} of {len(results)} sets built")
    alt = [s for s, r in results.items() if r == "alternate"]
    if alt:
        print(f"!!! ON ALTERNATE DISKS, NOT MAME'S: {', '.join(alt)}")
    gone = [s for s, r in results.items() if r == "missing"]
    if gone:
        print(f"!!! NOT BUILT, IMAGES NOT FOUND: {', '.join(gone)}")
    return 0 if built else 1


if __name__ == "__main__":
    sys.exit(main())
