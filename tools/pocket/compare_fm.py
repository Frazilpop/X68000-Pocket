#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The FM chips against MAME's YM2151, sample for sample.

    python3 -I tools/pocket/compare_fm.py MAME_DIR BENCH_DIR [SECONDS]

MAME_DIR is a tools/mame_x68k_sound.lua run's (its ym2151.f32, the chip's own 62.5 kHz before
MAME's mix); BENCH_DIR the FM bench's (sim/sound: jt51 and IKAOPM fed that run's writes at the
same times), so the three play the same notes from the same moment and can be set side by
side sample by sample. Four outputs are tried: jt51's left/right (the YM3012's 10.3 floating
point, as the chip puts out), jt51's xleft/xright (full resolution, what the board uses), and
IKAOPM's o_EMU (floating point) and o_EMU_EX (full resolution).

For each, the lag that lines it up with MAME's (found once, on the loudest second), then a
second at a time: the gain that best fits it to MAME's and the signal to error ratio left
after that gain, in dB. Seconds with less than -50 dBFS in MAME's are left out. A good
emulation of the same chip gives tens of dB; a wrong note or envelope, a few.
Only the standard library: a minute or two.
"""
import math
import os
import sys
from array import array
from operator import mul

RATE = 62500


def mame(d):
    a = array('f')
    with open(os.path.join(d, 'ym2151.f32'), 'rb') as f:
        a.frombytes(f.read())
    if sys.byteorder != 'little':
        a.byteswap()
    return [array('d', (v * 32768 for v in a[c::2])) for c in range(2)]


def bench(path):
    a = array('h')
    with open(path, 'rb') as f:
        a.frombytes(f.read())
    if sys.byteorder != 'little':
        a.byteswap()
    return [array('d', a[c::4]) for c in range(4)]


def dot(a, b):
    return sum(map(mul, a, b))


def lag_of(ref, x, i0, n, span=200):
    best, best_lag = -1e300, 0
    r = ref[i0:i0 + n]
    for lag in range(-span, span + 1):
        if i0 + lag < 0:
            continue
        v = dot(r, x[i0 + lag:i0 + lag + n])
        if v > best:
            best, best_lag = v, lag
    return best_lag


def main():
    md, bd = sys.argv[1], sys.argv[2]
    secs = float(sys.argv[3]) if len(sys.argv) > 3 else 1e9
    ref = mame(md)
    jt = bench(os.path.join(bd, 'jt51.s16'))
    ika = bench(os.path.join(bd, 'ikaopm.s16'))
    first = {}
    for line in open(os.path.join(bd, 'bench.txt')):
        k, *v = line.split()
        first[k] = float(v[0])
    # the bench's first sample is at its own time; MAME's sample i at i / RATE
    off = {'jt51': round(first['jt51'] * RATE), 'ikaopm': round(first['ikaopm'] * RATE)}
    n = min(len(ref[0]), int(secs * RATE))
    outs = [('jt51 left (10.3 fp)', jt[0], jt[1], 'jt51'), ('jt51 xleft (full)', jt[2], jt[3], 'jt51'),
            ('IKAOPM o_EMU (10.3 fp)', ika[0], ika[1], 'ikaopm'), ('IKAOPM o_EMU_EX (full)', ika[2], ika[3], 'ikaopm')]
    # the loudest second, for the lag
    loud, loud_i = -1, 0
    for s in range(0, n - RATE, RATE):
        e = dot(ref[0][s:s + RATE], ref[0][s:s + RATE])
        if e > loud:
            loud, loud_i = e, s
    floor = (32768 * 10 ** (-50 / 20)) ** 2 * RATE
    print(f"MAME's {n / RATE:.1f} s, the loudest second at {loud_i / RATE:.0f} s")
    print(f"{'output':26} {'ch':2} {'lag':>4} {'gain':>6} {'SNR all':>8} {'median':>7} {'worst':>6} {'secs':>4}")
    for name, xl, xr, k in outs:
        for ch, x in (('L', xl), ('R', xr)):
            # pad the bench's samples to MAME's time axis
            x = array('d', bytes(8 * max(0, off[k]))) + x
            r = ref[0 if ch == 'L' else 1]
            lag = lag_of(r, x, loud_i, 4096)
            snrs, se, sn = [], 0.0, 0.0
            gains = []
            for s in range(0, n - RATE, RATE):
                a = r[s:s + RATE]
                if s + lag < 0 or s + lag + RATE > len(x):
                    continue
                b = x[s + lag:s + lag + RATE]
                aa = dot(a, a)
                if aa < floor:
                    continue
                bb = dot(b, b)
                ab = dot(a, b)
                g = ab / bb if bb else 0.0
                err = aa - 2 * g * ab + g * g * bb
                snrs.append(10 * math.log10(aa / err) if err > 0 else 99.0)
                gains.append(g)
                se += aa
                sn += max(err, 0.0)
            if not snrs:
                print(f"{name:26} {ch:2} no seconds with sound")
                continue
            snrs_s = sorted(snrs)
            print(f"{name:26} {ch:2} {lag:4d} {sorted(gains)[len(gains) // 2]:6.3f} {10 * math.log10(se / sn) if sn else 99:8.1f} "
                  f"{snrs_s[len(snrs_s) // 2]:7.1f} {snrs_s[0]:6.1f} {len(snrs):4d}")


if __name__ == '__main__':
    main()
