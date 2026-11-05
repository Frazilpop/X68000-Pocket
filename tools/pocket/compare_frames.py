#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Two simulations' frames.txt, by each frame's checksum: how much of one's sequence the other shows too,
in order. Timing can put them apart by frames, or a frame more of one picture, but a game that runs alike
draws the same pictures, and a sprite a dot off is a checksum no one else has.

    python3 -I tools/pocket/compare_frames.py A/frames.txt B/frames.txt [--from N]

Lists the frames of A whose picture B never shows, as runs, up to the frame where B's run ends.
"""
import argparse

def read(p):
    return [l.split() for l in open(p)]

ap = argparse.ArgumentParser()
ap.add_argument('a'); ap.add_argument('b')
ap.add_argument('--from', dest='lo', type=int, default=3)
args = ap.parse_args()
A, B = read(args.a), read(args.b)
seen = {f[4]: int(f[0]) for f in reversed(B)}
last_b = {}
for f in B:
    last_b[f[4]] = int(f[0])
print(f'{args.a}: {len(A)} frames, {len(set(f[4] for f in A))} pictures; {args.b}: {len(B)} frames, {len(seen)} pictures')
# Walk A in order with a position in B that only goes forward.
pos = 0
index = {}
for i, f in enumerate(B):
    index.setdefault(f[4], []).append(i)
match = miss = 0
runs = []
for f in A:
    n = int(f[0])
    if n < args.lo:
        continue
    if pos >= len(B) - 1 and f[4] not in index:
        break
    hits = [i for i in index.get(f[4], []) if i >= pos]
    if hits:
        pos = hits[0]
        match += 1
    else:
        miss += 1
        if runs and runs[-1][1] == n - 1:
            runs[-1][1] = n
        else:
            runs.append([n, n, f[1] + 'x' + f[2]])
print(f'{match} frames of {args.a} in order in {args.b}, reaching its frame {B[pos][0]}; {miss} not')
for r in runs[:40]:
    print(f'  not there: frames {r[0]} to {r[1]} ({r[2]})')
