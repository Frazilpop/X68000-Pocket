#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""What taking the FM chip's 62.5 kHz at the Pocket's 48 kHz does to it, and what a resampler would.

    /usr/bin/python3 tools/pocket/audio_alias.py FILE.s16 [--stride N] [--col K] [--from S] [--secs S] [--taps T] [--cut HZ]

FILE.s16 holds the chip's own samples, signed 16-bit, at 62.5 kHz: the simulation's fm.s16
(--stride 2, --col 0 left) or the FM bench's jt51.s16 (--stride 4, --col 2 xleft). numpy and scipy.

  * As built, sound_i2s takes whatever the board holds at each 48 kHz tick: the chip's
    sample-and-hold read at 48 kHz. Everything of the held wave above 24 kHz folds down, and
    the hold's images at 62.5 kHz +- f fold to 14.5 kHz -+ f, off the music's pitch.
  * Against it, the same held wave band-limited properly (to 1 MHz by holding, then scipy's
    resample_poly to 48 kHz): what a low-pass and a 48 kHz converter would give, the reference.
  * And a resampler of Cave's kind: a T-tap Kaiser low-pass at 62.5 kHz cut at HZ, then linear
    interpolation at 48 kHz, against the chip's samples band-limited the same reference way.
  * And a polyphase one (--poly N --phases P --bits B): each 48 kHz sample straight from the N
    nearest 62.5 kHz ones, a Kaiser-windowed sinc cut at HZ taken at the nearest of P fractional
    positions, its taps rounded to B bits.
Each: the error's power under 16 kHz and under 20 kHz against the signal's, in dB (lower is better).
"""
import argparse
import numpy as np
from scipy.signal import firwin, resample_poly, butter, sosfiltfilt

FS, OUT = 62500, 48000


def band_db(err, sig, hz):
    sos = butter(10, hz, fs=OUT, output='sos')
    e, s = sosfiltfilt(sos, err), sosfiltfilt(sos, sig)
    return 10 * np.log10(np.sum(e * e) / np.sum(s * s))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('file')
    ap.add_argument('--stride', type=int, default=2)
    ap.add_argument('--col', type=int, default=0)
    ap.add_argument('--from', dest='start', type=float, default=0)
    ap.add_argument('--secs', type=float, default=10)
    ap.add_argument('--taps', type=int, default=63)
    ap.add_argument('--cut', type=float, default=20000)
    ap.add_argument('--poly', type=int, default=0)
    ap.add_argument('--phases', type=int, default=64)
    ap.add_argument('--beta', type=float, default=8.0)
    ap.add_argument('--bits', type=int, default=0)
    a = ap.parse_args()
    x = np.fromfile(a.file, dtype='<i2')[a.col::a.stride].astype(np.float64)
    x = x[int(a.start * FS):int((a.start + a.secs) * FS)]
    n_out = int(len(x) * OUT / FS) - 64
    t = np.arange(n_out) / OUT
    # as built: the held sample at each 48 kHz tick
    ps = x[np.floor(t * FS).astype(np.int64)]
    # the reference for it: the held wave at 1 MHz, band-limited to 48 kHz
    up = 16
    held = np.repeat(x, up)                               # 1 MHz
    ref_held = resample_poly(held, 6, 125, window=('kaiser', 10.0))[:n_out]   # 1e6 * 6 / 125 = 48 kHz
    sl = slice(200, n_out - 200)
    print(f"{a.file}: {len(x) / FS:.1f} s from {a.start:.1f} s, level {np.sqrt(np.mean(x * x)):.0f} rms")
    print(f"  as built (held, read at 48 kHz): folding {band_db(ps[sl] - ref_held[sl], ref_held[sl], 16000):6.1f} dB under 16 kHz, "
          f"{band_db(ps[sl] - ref_held[sl], ref_held[sl], 20000):6.1f} under 20 kHz")
    # a resampler of Cave's kind
    h = firwin(a.taps, a.cut, window=('kaiser', 6.0), fs=FS)
    y = np.convolve(x, h)[a.taps // 2:a.taps // 2 + len(x)]   # centred: no delay
    p = t * FS
    k = np.floor(p).astype(np.int64)
    f = p - k
    lin = y[k] * (1 - f) + y[np.minimum(k + 1, len(y) - 1)] * f
    ref = resample_poly(x, 96, 125, window=('kaiser', 10.0))[:n_out]         # 62.5 kHz * 96 / 125 = 48 kHz
    if a.poly:
        # as pocket_audio_resample does it: the phase is floor(fraction * P), standing for its middle
        from audio_poly import table
        n, P = a.poly, a.phases
        js = np.arange(n) - (n // 2 - 1)
        tab = table(n, P, a.cut, a.beta, a.bits)
        ph = np.minimum(np.floor(f * P).astype(int), P - 1)
        idx = np.clip(k[:, None] + js[None, :], 0, len(x) - 1)
        poly = np.sum(x[idx] * tab[ph], axis=1)
        print(f"  {n}-tap polyphase, {P} phases, cut {a.cut / 1000:.1f} kHz{f', {a.bits}-bit taps' if a.bits else ''}: error "
              f"{band_db(poly[sl] - ref[sl], ref[sl], 16000):6.1f} dB under 16 kHz, {band_db(poly[sl] - ref[sl], ref[sl], 20000):6.1f} under 20 kHz")
    print(f"  {a.taps}-tap low-pass at {a.cut / 1000:.1f} kHz, then linear: error {band_db(lin[sl] - ref[sl], ref[sl], 16000):6.1f} dB under 16 kHz, "
          f"{band_db(lin[sl] - ref[sl], ref[sl], 20000):6.1f} under 20 kHz")


if __name__ == '__main__':
    main()
