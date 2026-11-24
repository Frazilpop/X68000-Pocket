#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""What a save state would send, from tools/mame_x68k_census.lua's DUMP_AT lines.

    python3 -I tools/pocket/state_blocks.py build/state_blocks/*.log
    python3 -I tools/pocket/state_blocks.py --block 4096 --frames build/state_blocks/sf2ce.log

The state's format (main RAM after 1.1 MB of the rest) is sent whole, or with its blocks of
zeros (and, with "uniform", of one repeated long) left out behind a bitmap. The time is the
Pocket's own pace, measured on the card: a save 0.35 s + 6.59 s a MiB, a load 0.07 s + 1.52 s
a MiB.

For each log: each dump's main RAM, GVRAM, TVRAM and EB0000-EBFFFF in blocks left out and sent,
and the Memory's size and save time under each way of sending it; then a line a set (the
largest dump, the median) and the ten's figures together.
"""

import argparse
import os
import statistics
import sys

KB, MIB = 1024, 1 << 20
SMALL = 0x8000              # header, board, 68000, ports, FDC buffer, shadow, palettes, SRAM
PAD = 0x8000                # the zero gap before TVRAM, left out like any zero block
REGIONS = ("eb", "tvram", "gvram", "ram")


def save_s(n):
    return 0.35 + 6.59 * n / MIB


def load_s(n):
    return 0.07 + 1.52 * n / MIB


def read_log(path):
    dumps = {}
    for line in open(path):
        if not line.startswith("B "):
            continue
        p = line.split()
        frame, region, n = int(p[1]), p[2], int(p[3])
        toks = p[4:4 + n]
        assert len(toks) == n, (path, frame, region)
        dumps.setdefault(frame, {})[region] = toks
    return dumps


def merge(toks, k):
    """1 KB tokens into blocks of k KB: 0 when all zero, x when mixed, the long when one repeats."""
    out = []
    for i in range(0, len(toks), k):
        g = toks[i:i + k]
        if all(t == "0" for t in g):
            out.append("0")
        elif "x" not in g and len(set(g)) == 1:
            out.append(g[0])
        else:
            out.append("x")
    return out


def sizes(d, k):
    """The Memory's bytes: whole; zeros left out; zeros and uniform blocks left out; RAM's zeros only."""
    blk = k * KB
    whole = SMALL + PAD + sum(len(d[r]) * KB for r in REGIONS)
    nblk = (whole - SMALL) // blk
    bitmap = (nblk + 7) // 8
    sent_z = sent_u = 0
    uni = 0
    per = {}
    for r in REGIONS:
        m = merge(d[r], k)
        z = sum(t == "0" for t in m)
        x = sum(t == "x" for t in m)
        u = len(m) - z - x
        per[r] = (z, u, x, len(m))
        sent_z += (len(m) - z) * blk
        sent_u += x * blk
        uni += u
    zero_only = SMALL + bitmap + sent_z
    with_uni = SMALL + 2 * bitmap + 4 * uni + sent_u
    zr, ur, xr, nr = per["ram"]
    ram_only = SMALL + PAD + sum(len(d[r]) * KB for r in REGIONS if r != "ram") \
        + (nr + 7) // 8 + (nr - zr) * blk
    return dict(whole=whole, zero=zero_only, uniform=with_uni, ram_only=ram_only, per=per)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("logs", nargs="+")
    ap.add_argument("--block", type=int, default=4096, help="block size in bytes (1024, 4096, 16384)")
    ap.add_argument("--frames", action="store_true", help="every dump, not only the summary")
    a = ap.parse_args()
    k = a.block // KB
    assert k in (1, 2, 4, 8, 16, 32, 64), "block: a power of two from 1 KB to 64 KB"

    rows = []
    for path in a.logs:
        name = os.path.basename(path).rsplit(".", 1)[0]
        dumps = read_log(path)
        if not dumps:
            print(f"{name}: no B lines", file=sys.stderr)
            continue
        res = {f: sizes(d, k) for f, d in sorted(dumps.items())}
        if a.frames:
            print(f"## {name}, {a.block // KB} KB blocks (left out zero / uniform / sent, of all)")
            for f, s in res.items():
                parts = "  ".join(f"{r} {z}/{u}/{x} of {n}" for r, (z, u, x, n) in s["per"].items())
                print(f"  {f:6d}  {parts}  ->  {s['zero'] / MIB:5.2f} MiB {save_s(s['zero']):5.1f} s,"
                      f" uniform too {s['uniform'] / MIB:5.2f} MiB {save_s(s['uniform']):5.1f} s,"
                      f" RAM only {s['ram_only'] / MIB:5.2f} MiB {save_s(s['ram_only']):5.1f} s")
        worst = max(res.items(), key=lambda kv: kv[1]["zero"])
        med = statistics.median(s["zero"] for s in res.values())
        med_u = statistics.median(s["uniform"] for s in res.values())
        med_r = statistics.median(s["ram_only"] for s in res.values())
        rows.append((name, worst[0], worst[1], med, med_u, med_r, len(res)))

    whole = rows[0][2]["whole"] if rows else 0
    print(f"\n{a.block // KB} KB blocks; the whole Memory {whole / MIB:.2f} MiB, save {save_s(whole):.1f} s,"
          f" load {load_s(whole):.1f} s")
    print(f"{'set':10} {'dumps':>5} {'largest at':>10} {'MiB':>6} {'save':>6} {'load':>5}   "
          f"{'median MiB':>10} {'save':>6} {'load':>5}   {'uniform too':>11} {'RAM only':>9}")
    for name, f, w, med, med_u, med_r, n in rows:
        print(f"{name:10} {n:5d} {f:10d} {w['zero'] / MIB:6.2f} {save_s(w['zero']):5.1f}s {load_s(w['zero']):4.1f}s"
              f"   {med / MIB:10.2f} {save_s(med):5.1f}s {load_s(med):4.1f}s"
              f"   {save_s(med_u):10.1f}s {save_s(med_r):8.1f}s")
    if rows:
        meds = sorted(r[3] for r in rows)
        m = statistics.median(meds)
        print(f"the sets' medians: median {m / MIB:.2f} MiB, save {save_s(m):.1f} s, load {load_s(m):.1f} s;"
              f" largest {max(r[2]['zero'] for r in rows) / MIB:.2f} MiB")


if __name__ == "__main__":
    main()
