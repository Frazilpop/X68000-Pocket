#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Pairs each frame of a simulation with the picture of another run that shows the same, going by what
they show and not by number: MAME has no HRL and a line 8 dots short, so frame N of one is not frame N
of the other. Python's own library only, with exact rows skipped, so a sheet of frames takes seconds.

    python3 -I tools/pocket/match_frames.py SIMDIR OTHERDIR [--from N] [--to N] [--near N]

SIMDIR holds f_NNNNN.png, OTHERDIR f_NNNNN.png or MAME's mNNNNN.png. Each pairing is shown with its
count of dots that differ, on what they have in common; it says when the sizes differ.
"""
import argparse, glob, os, re, struct, sys, zlib

def png(path):
    d = open(path, 'rb').read()
    i = 8; z = []; w = h = bpp = 0
    while i < len(d):
        n = struct.unpack('>I', d[i:i + 4])[0]
        t = d[i + 4:i + 8]
        if t == b'IHDR':
            w, h, depth, ctype = struct.unpack('>IIBB', d[i + 8:i + 18])
            assert depth == 8 and ctype in (2, 6), f'{path}: colour type {ctype}'
            bpp = 3 if ctype == 2 else 4
        elif t == b'IDAT':
            z.append(d[i + 8:i + 8 + n])
        i += 12 + n
    r = zlib.decompress(b''.join(z))
    s = w * bpp + 1
    rows = []
    prev = bytearray(s - 1)
    for y in range(h):
        f = r[y * s]
        cur = bytearray(r[y * s + 1:(y + 1) * s])
        if f == 1:
            for x in range(bpp, len(cur)):
                cur[x] = (cur[x] + cur[x - bpp]) & 255
        elif f == 2:
            for x in range(len(cur)):
                cur[x] = (cur[x] + prev[x]) & 255
        elif f == 3:
            for x in range(len(cur)):
                a = cur[x - bpp] if x >= bpp else 0
                cur[x] = (cur[x] + ((a + prev[x]) >> 1)) & 255
        elif f == 4:
            for x in range(len(cur)):
                a = cur[x - bpp] if x >= bpp else 0
                b = prev[x]
                c = prev[x - bpp] if x >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if pa <= pb and pa <= pc else b if pb <= pc else c
                cur[x] = (cur[x] + pr) & 255
        prev = cur
        if bpp == 4:
            rgb = bytearray(w * 3); rgb[0::3] = cur[0::4]; rgb[1::3] = cur[1::4]; rgb[2::3] = cur[2::4]
            rows.append(bytes(rgb))
        else:
            rows.append(bytes(cur))
    return w, h, rows

MASK = None
DY = 0
BY_MAP = False

def diff_mapped(a, b):
    """As diff, but a colour counts as the same if it always goes to one colour of the other's: MAME's
    snapshot leaves out the machine's contrast, and widens 5 bits another way. Against MAME with
    --dy -1: its raster sits a line above this one's."""
    pairs = {}
    xb = max(0, b[0] - a[0]) * 3
    ya = max(0, a[1] - b[1]) // 2       # a raster shorter than the box sits in its middle
    for y in range(ya, a[1] - ya):
        if not 0 <= y - ya + DY < b[1]:
            continue
        ra, rb = a[2][y], b[2][y - ya + DY]
        for x in range(0, a[0] * 3, 3):
            k = ra[x:x + 3]
            d = pairs.setdefault(k, {})
            v = rb[xb + x:xb + x + 3]
            d[v] = d.get(v, 0) + 1
    if len(pairs) < 2:
        return 1 << 40                  # one colour says nothing
    fwd = sum(sum(d.values()) - max(d.values()) for d in pairs.values())
    back = {}
    for k, d in pairs.items():
        for v, n in d.items():
            e = back.setdefault(v, {})
            e[k] = e.get(k, 0) + n
    return max(fwd, sum(sum(e.values()) - max(e.values()) for e in back.values()))

def diff(a, b):
    """a's dots against b's. MAME's picture has its lamp panel on the left, so a wider b is taken from its
    right-hand end; a raster shorter than the box sits in its middle."""
    w = min(a[0], b[0]) * 3
    xa, xb = max(0, a[0] - b[0]) * 3, max(0, b[0] - a[0]) * 3
    ya, yb = max(0, a[1] - b[1]) // 2, max(0, b[1] - a[1]) // 2
    n = 0
    for y in range(min(a[1], b[1])):
        ra, rb = a[2][y + ya][xa:xa + w], b[2][y + yb][xb:xb + w]
        if MASK:
            ra, rb = ra.translate(MASK), rb.translate(MASK)
        if ra == rb:
            continue
        for x in range(0, w, 3):
            if ra[x:x + 3] != rb[x:x + 3]:
                n += 1
    return n

def num(p):
    return int(re.search(r'(\d+)\.png$', p).group(1))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('sim'); ap.add_argument('other')
    ap.add_argument('--from', dest='lo', type=int, default=0)
    ap.add_argument('--to', dest='hi', type=int, default=1 << 30)
    ap.add_argument('--near', type=int, default=0, help='only look this many frames either side of the last match')
    ap.add_argument('--bits', type=int, default=8, help="compare only this many of each colour's top bits: MAME widens 5 bits another way")
    ap.add_argument('--map', action='store_true', help='compare under a colour map')
    ap.add_argument('--dy', type=int, default=0)
    args = ap.parse_args()
    global MASK, DY, BY_MAP
    DY, BY_MAP = args.dy, args.map
    if args.bits < 8:
        m = (0xff << (8 - args.bits)) & 0xff
        MASK = bytes(i & m for i in range(256))
    S = sorted(glob.glob(os.path.join(args.sim, 'f_*.png')))
    O = sorted(glob.glob(os.path.join(args.other, '[fm]*.png')), key=num)
    pics = {}
    last = None
    for p in S:
        f = num(p)
        if f < args.lo or f > args.hi:
            continue
        s = png(p)
        best = None
        for q in O:
            k = num(q)
            if last is not None and args.near and abs(k - last) > args.near:
                continue
            if k not in pics:
                pics[k] = png(q)
            o = pics[k]
            # the same mode only: as wide, or as wide with MAME's panel, no more than 8 % wider
            if not (s[0] <= o[0] <= s[0] * 1.08) or o[1] > s[1]:
                continue
            n = (diff_mapped if BY_MAP else diff)(s, o)
            if best is None or n < best[0]:
                best = (n, k, o)
                if n == 0:
                    break
        if best:
            n, k, o = best
            size = '' if (s[0], s[1]) == (o[0], o[1]) else f' (sizes {s[0]}x{s[1]} and {o[0]}x{o[1]})'
            print(f'sim {f:5d} ~ {k:5d}: {n:6d} dots differ of {min(s[0], o[0]) * min(s[1], o[1])}{size}')
            last = k

if __name__ == '__main__':
    main()
