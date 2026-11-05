#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compares two of the machine's bus traces, line for line, MAME's or a simulation's.

    python3 -I tools/pocket/diff_x68k_trace.py a.txt b.txt [--context N] [--resync N] [--skip-poll]

A line is `<addr> <R|W> <data> <mask>`, '#' lines are skipped; data is compared on its mask's lanes.
At the first difference it prints the lines either side and what they have reached. --resync N looks
up to N lines ahead on either side for the two to run alike again and carries on, counting each break,
which gets a run past a timing loop's count: each break is a place the machines' timing shows, and
the count of lines matched says how far the program stayed the same.
"""
import argparse, sys

def read(path):
    out = []
    with open(path) as f:
        for line in f:
            if line[0] == '#':
                continue
            p = line.split()
            if len(p) < 4:
                continue
            m = int(p[3], 16)
            out.append((int(p[0], 16), p[1], int(p[2], 16) & m, m))
    return out

def region(a):
    table = [(0x000000, 0xc00000, 'main RAM'), (0xc00000, 0xe00000, 'GVRAM'), (0xe00000, 0xe80000, 'TVRAM'), (0xe80000, 0xe82000, 'CRTC'),
             (0xe82000, 0xe84000, 'palette/VC'), (0xe84000, 0xe86000, 'DMAC'), (0xe86000, 0xe88000, 'area'), (0xe88000, 0xe8a000, 'MFP'), (0xe8a000, 0xe8c000, 'RTC'),
             (0xe8c000, 0xe8e000, 'printer'), (0xe8e000, 0xe90000, 'system port'), (0xe90000, 0xe92000, 'OPM'), (0xe92000, 0xe94000, 'ADPCM'), (0xe94000, 0xe96000, 'FDC'),
             (0xe96000, 0xe98000, 'SASI'), (0xe98000, 0xe9a000, 'SCC'), (0xe9a000, 0xe9c000, 'PPI'), (0xe9c000, 0xe9e000, 'IOC'), (0xeb0000, 0xeb8000, 'sprite regs'),
             (0xeb8000, 0xec0000, 'PCG/BG'), (0xed0000, 0xed4000, 'SRAM'), (0xf00000, 0xfc0000, 'CG ROM'), (0xfc0000, 0xfe0000, 'SCSI ROM'), (0xfe0000, 0x1000000, 'IPL ROM')]
    for lo, hi, n in table:
        if lo <= a < hi:
            return n
    return '?'

def show(x):
    return f'{x[0]:06x} {x[1]} {x[2]:04x} {x[3]:04x} {region(x[0])}'

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('a'); ap.add_argument('b')
    ap.add_argument('--context', type=int, default=8)
    ap.add_argument('--resync', type=int, default=0)
    ap.add_argument('--breaks', type=int, default=30)
    args = ap.parse_args()
    A, B = read(args.a), read(args.b)
    print(f'{args.a}: {len(A)} accesses; {args.b}: {len(B)}')
    i = j = same = 0
    breaks = []
    while i < len(A) and j < len(B):
        if A[i] == B[j]:
            i += 1; j += 1; same += 1
            continue
        where = (i, j)
        if not breaks or args.resync == 0:
            print(f'first difference after {same} identical accesses:' if not breaks else f'difference after {same}:')
            for k in range(max(0, i - args.context), i):
                print(f'  same {show(A[k])}')
            for k in range(0, args.context):
                l = show(A[i + k]) if i + k < len(A) else ''
                r = show(B[j + k]) if j + k < len(B) else ''
                print(f'  {l:44s} | {r}')
        breaks.append(where)
        if args.resync == 0:
            break
        # the nearest place both run alike for 16 lines, by the sum of what's skipped
        found = None
        for d in range(1, args.resync):
            for da in range(0, d + 1):
                db = d - da
                if i + da + 16 < len(A) and j + db + 16 < len(B) and A[i + da:i + da + 16] == B[j + db:j + db + 16]:
                    found = (da, db); break
            if found:
                break
        if not found:
            print(f'no way back within {args.resync} lines, at break {len(breaks)}: {show(A[i])} | {show(B[j])}')
            for k in range(0, args.context):
                l = show(A[i + k]) if i + k < len(A) else ''
                r = show(B[j + k]) if j + k < len(B) else ''
                print(f'  {l:44s} | {r}')
            break
        if len(breaks) <= args.breaks:
            print(f'break {len(breaks)} at {same} same: {args.a} skips {found[0]} from {show(A[i])}; {args.b} skips {found[1]} from {show(B[j])}')
        i += found[0]; j += found[1]
    print(f'{same} accesses identical, {len(breaks)} break(s), to {i} and {j} of {len(A)} and {len(B)}')

if __name__ == '__main__':
    main()
