#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The taps of pocket_audio_resample: the machine's 62.5 kHz to the Pocket's 48 kHz.

    /usr/bin/python3 tools/pocket/audio_poly.py            write pocket/src/fpga/core/pocket_audio_poly.hex
    /usr/bin/python3 tools/pocket/audio_poly.py --response the response at a few frequencies

Each 48 kHz sample is made from the 24 latest 62.5 kHz ones, by a Kaiser-windowed sinc (beta 8)
cut at 20 kHz, taken at one of 64 fractional positions: phase p stands for (p + 0.5) / 64 of a
sample past the output's time, so the module's phase, the clocks since its last sample over 10
(640 clocks a sample), is never more than half a phase out. Taps are signed 18 bits, 1.0 = 2^17,
each phase's sum exactly 2^17 so a held level stays as it is. The hex file holds 2,048 words,
phase * 32 + tap, the oldest sample's tap first, the 8 words above 23 in each phase zero.
tools/pocket/audio_alias.py --poly 24 --phases 64 --bits 18 models it (numpy).
"""
import os
import sys
import numpy as np

N, P, CUT, FS, BETA, ONE = 24, 64, 20000.0, 62500.0, 8.0, 1 << 17


def table(n=N, phases=P, cut=CUT, beta=BETA, bits=18):
    """Rows by phase; columns the taps for samples k - n/2 + 1 .. k + n/2 around the output's
    time k + (phase + 0.5) / phases."""
    js = np.arange(n) - (n // 2 - 1)
    w = np.kaiser(2 * n * 64 + 1, beta)
    tab = np.zeros((phases, n))
    for ph in range(phases):
        u = js - (ph + 0.5) / phases
        g = 2 * cut / FS * np.sinc(2 * cut / FS * u)
        wi = np.clip(np.round((u / n + 0.5) * (len(w) - 1)).astype(int), 0, len(w) - 1)
        g = g * w[wi]
        g = g / g.sum()
        if bits:
            one = 1 << (bits - 1)
            q = np.round(g * one).astype(np.int64)
            q[np.argmax(q)] += one - q.sum()
            g = q / one
        tab[ph] = g
    return tab


def main():
    tab = table()
    if '--response' in sys.argv:
        # the whole filter as one long one at 64 x 62.5 kHz: phase p's taps interleaved
        h = np.zeros(N * P)
        for ph in range(P):
            for j in range(N):
                h[j * P + (P - 1 - ph)] = tab[ph, j]
        h /= h.sum()
        for f in (1000, 5000, 10000, 15000, 18000, 20000, 22000, 24000, 26000, 30000, 40000, 50000, 60000):
            r = abs(np.sum(h * np.exp(-2j * np.pi * f / (FS * P) * np.arange(len(h)))))
            print(f"{f:6d} Hz  {20 * np.log10(r + 1e-12):7.2f} dB")
        return
    q = np.round(tab * ONE).astype(np.int64)
    out = os.path.join(os.path.dirname(__file__), '..', '..', 'pocket', 'src', 'fpga', 'core', 'pocket_audio_poly.hex')
    with open(out, 'w') as f:
        for ph in range(P):
            for j in range(32):
                v = int(q[ph, j]) if j < N else 0     # word j: the tap for sample K - 23 + j, oldest first
                f.write(f"{v & 0x3FFFF:05x}\n")
    print(f"written {os.path.normpath(out)}: {P} phases of {N} taps, largest {q.max()}, smallest {q.min()}")


if __name__ == '__main__':
    main()
