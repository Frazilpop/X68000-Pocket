#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The machine's sound in simulation against MAME's, from the writes to the output.

    python3 -I tools/pocket/compare_sound.py SIM_DIR MAME_DIR

SIM_DIR is a sim/gradius run's with --audio (sound_writes.txt, pcm.txt, fm.s16, audio.wav);
MAME_DIR a tools/mame_x68k_sound.lua run's (writes.txt, ym2151.f32, okim6258.f32, index.txt,
mix.wav), the same set from power-on. The two machines don't keep the same time (the disk, the
CPU's waits), so each part is compared in order and then lined up by its own events:

  * FM: the register writes in order, as (register, value) pairs, over the span the simulation
    reached. Writes to register 0x14 are left out: they answer the timers, so their place is which
    timer fired first. Then the two sequences matched (difflib), as a write to 0x1B (the ADPCM's
    clock, from another part of the program) can fall a little earlier or later among the music's.
  * ADPCM: the commands (E92001), the data bytes the DMA brought (E92003), and port C of the PPI
    (pan and rate), each in order.
  * The decoder: the simulation's decoded 12 bits (pcm.txt, each change) against the same bytes
    decoded by the MSM6258's rules here, play by play: says the DMA kept up and the decoder
    decodes. MAME's own samples against its bytes decoded the same way with its 10-bit limit,
    which shows where MAME's rule and the board's part.
  * Levels: each chip's level in the two over the same notes, lined up by the FM writes' times,
    and the mixes' levels.
Only the standard library.
"""
import math
import os
import sys
import wave
from array import array
from difflib import SequenceMatcher
from bisect import bisect_left

STEP = [16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190,
        209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552]
SHIFT = [-1, -1, -1, -1, 2, 4, 6, 8]


def writes(path):
    out = []
    for line in open(path):
        p = line.split()
        if len(p) == 3 and len(p[2]) == 2:      # a run still going may have half a line at the end
            out.append((float(p[0]), int(p[1], 16), int(p[2], 16)))
    return out


def fm_pairs(ws):
    reg, out = None, []
    for t, a, d in ws:
        if a == 0xe90001:
            reg = d
        elif a == 0xe90003 and reg is not None:
            if reg != 0x14:
                out.append((t, reg, d))
    return out


def plays(ws):
    """Each play: its start time, the bytes written while it ran, its stop time."""
    out, cur = [], None
    for t, a, d in ws:
        if a == 0xe92001:
            if d & 1:
                if cur:
                    cur[2] = t
                    out.append(cur)
                    cur = None
            elif d & 2 and cur is None:
                cur = [t, [], None]
        elif a == 0xe92003 and cur is not None:
            cur[1].append(d)
    if cur:
        out.append(cur)
    return out


def decode(data, limit, s=-2):
    i, out = 0, []
    for b in data:
        for nib in (b & 15, b >> 4):
            sv = STEP[i]
            d = sv // 8
            if nib & 1:
                d += sv // 4
            if nib & 2:
                d += sv // 2
            if nib & 4:
                d += sv
            s = s - d if nib & 8 else s + d
            s = max(-limit, min(limit - 1, s))
            i = max(0, min(48, i + SHIFT[nib & 7]))
            out.append(s)
    return out


def dedupe(seq):
    out = []
    for v in seq:
        if not out or out[-1] != v:
            out.append(v)
    return out


def same_run(a, b):
    n = 0
    for x, y in zip(a, b):
        if x != y:
            break
        n += 1
    return n


def rms(a):
    return math.sqrt(sum(v * v for v in a) / len(a)) if a else 0.0


def wav(path):
    w = wave.open(path)
    n, ch, rate = w.getnframes(), w.getnchannels(), w.getframerate()
    a = array('h')
    a.frombytes(w.readframes(n))
    if sys.byteorder != 'little':
        a.byteswap()
    return [a[c::ch] for c in range(ch)], rate


def main():
    sd, md = sys.argv[1], sys.argv[2]
    sw, mw = writes(os.path.join(sd, 'sound_writes.txt')), writes(os.path.join(md, 'writes.txt'))
    print(f"writes: simulation {len(sw)} to {sw[-1][0] / 1e6 if sw else 0:.2f} s, MAME {len(mw)} to {mw[-1][0] / 1e6 if mw else 0:.2f} s")

    # ---------------------------------------------------------------- FM
    sf, mf = fm_pairs(sw), fm_pairs(mw)
    n = same_run([p[1:] for p in sf], [p[1:] for p in mf])
    print(f"\nFM: {len(sf)} register writes in the simulation, {len(mf)} in MAME (0x14 left out); "
          f"the first {n} identical in order", end='')
    if n < min(len(sf), len(mf)):
        print(f"; then simulation {sf[n][1]:02x}={sf[n][2]:02x} at {sf[n][0] / 1e6:.4f} s against MAME {mf[n][1]:02x}={mf[n][2]:02x} at {mf[n][0] / 1e6:.4f} s")
        print("   the next 6 each side:", [f"{r:02x}={v:02x}" for _, r, v in sf[n:n + 6]], [f"{r:02x}={v:02x}" for _, r, v in mf[n:n + 6]])
    else:
        print(" (all of the shorter)")
    # the span the simulation reached: MAME's writes up to as many again as it made, and a little more
    mf_span = mf[:len(sf) + 200]
    sm = SequenceMatcher(None, [p[1:] for p in sf], [p[1:] for p in mf_span], autojunk=False)
    blocks = [b for b in sm.get_matching_blocks() if b.size]
    matched = sum(b.size for b in blocks)
    print(f"   matched as sequences: {matched} of the simulation's {len(sf)} in {len(blocks)} runs; ", end='')
    odd = []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag != 'equal':
            odd.append(f"{tag} sim[{i1}:{i2}] {[f'{r:02x}={v:02x}' for _, r, v in sf[i1:min(i2, i1 + 4)]]} "
                       f"MAME[{j1}:{j2}] {[f'{r:02x}={v:02x}' for _, r, v in mf_span[j1:min(j2, j1 + 4)]]}")
    print(f"{len(odd)} places differ" + (", the first few:" if odd else ""))
    for o in odd[:8]:
        print("     " + o)
    n = blocks[-1].a + blocks[-1].size if blocks else 0
    offs = []
    if blocks:
        # the times over the longest run of writes the two make alike: where both play the same notes
        big = max(blocks, key=lambda b: b.size)
        pairs = [(big.a + k, big.b + k) for k in range(big.size)]
        print(f"   the longest run alike: {big.size} writes, MAME's {mf_span[big.b][0] / 1e6:.2f} to {mf_span[big.b + big.size - 1][0] / 1e6:.2f} s")
        for q in (0, len(pairs) // 4, len(pairs) // 2, 3 * len(pairs) // 4, len(pairs) - 1):
            i, j = pairs[q]
            offs.append((mf_span[j][0], sf[i][0] - mf_span[j][0]))
        print("   the simulation's time against MAME's at the same write: " +
              ", ".join(f"{m / 1e6:.2f} s: {d / 1e3:+.1f} ms" for m, d in offs))

    # ---------------------------------------------------------------- ADPCM writes
    for name, addr in (('ADPCM commands', 0xe92001), ('PPI port C', 0xe9a005), ('PPI control', 0xe9a007)):
        a = [d for _, x, d in sw if x == addr]
        b = [d for _, x, d in mw if x == addr]
        k = same_run(a, b)
        print(f"{name}: {len(a)} in the simulation, {len(b)} in MAME, the first {k} identical"
              + ("" if k >= min(len(a), len(b)) else f"; then {a[k]:02x} against {b[k]:02x}"))
    sp, mp = plays(sw), plays(mw)
    k = 0
    for x, y in zip(sp, mp):
        if x[1] != y[1]:
            break
        k += 1
    tot = sum(len(p[1]) for p in sp[:k])
    print(f"ADPCM plays: {len(sp)} in the simulation, {len(mp)} in MAME; the first {k} bring the same bytes ({tot} bytes)")
    if k < min(len(sp), len(mp)):
        x, y = sp[k][1], mp[k][1]
        j = same_run(x, y)
        print(f"   play {k}: {len(x)} bytes against {len(y)}, the same for {j}"
              + (f" (still running when the simulation ended)" if sp[k][2] is None else ""))

    # ---------------------------------------------------------------- the decoder
    pcm_t, pcm_v = [], []
    for line in open(os.path.join(sd, 'pcm.txt')):
        if len(line.split()) != 2 or not line.endswith('\n'):
            continue
        c, v = line.split()
        pcm_t.append(int(c) / 40.0)
        pcm_v.append(int(v))
    # Burst by burst: the DMA brings a block, then nothing for a while, and the chip runs dry in
    # between. Dry, the board's decoder sets its step to 0 and lets the level fall back to 0 (MAME's
    # decodes its last byte again and again, to the rail). So each burst decodes from wherever the
    # level stood when it came, with the step at 0, and that is what's checked.
    good = bad = tail = 0
    first_bad = []
    over10 = n12 = 0
    nbytes = 0
    for pi, (start, data, stop) in enumerate(sp):
        times = [t for t, a, _ in sw if a == 0xe92003 and t >= start and (stop is None or t < stop)]
        bursts, cur = [], []
        for t, b in zip(times, data):
            if cur and t - cur[-1][0] > 1000:
                bursts.append(cur)
                cur = []
            cur.append((t, b))
        if cur:
            bursts.append(cur)
        for bi, bu in enumerate(bursts):
            t0 = bu[0][0]
            i0 = bisect_left(pcm_t, t0)
            i1 = bisect_left(pcm_t, bursts[bi + 1][0][0]) if bi + 1 < len(bursts) else (bisect_left(pcm_t, stop) if stop else len(pcm_t))
            s0 = -2 if bi == 0 else (pcm_v[i0 - 1] if i0 else 0)
            full = decode([b for _, b in bu], 2048, s0)
            over10 += sum(1 for v in full if v > 511 or v < -512)
            n12 += len(full)
            nbytes += len(bu)
            want = dedupe([s0] + full)
            got = dedupe(([s0] if bi == 0 else []) + pcm_v[max(i0 - 1, 0) if bi else i0:i1])
            last = bi + 1 == len(bursts) and stop is None and i1 == len(pcm_t)
            if last:
                m = min(len(got), len(want))
                got, want = got[:m], want[:m]
            else:
                got = got[:len(want)]        # then the decoder runs dry and falls back
            if got == want:
                good += 1
            elif not last and len(want) > 8 and got[:len(want) - 8] == want[:len(want) - 8]:
                tail += 1                    # all but the last byte or two: overwritten before they played
            else:
                bad += 1
                j = same_run(got, want)
                if len(first_bad) < 4:
                    first_bad.append((t0, len(bu), len(want), j, got[max(j - 2, 0):j + 4], want[max(j - 2, 0):j + 4]))
    print(f"\nthe decoder: of {good + tail + bad} bursts of bytes ({nbytes} bytes), {good} decode exactly as the bytes say (12 bits), "
          f"{tail} but for their last byte or two (the DMA's last byte of a block comes a few us after the one before and "
          f"takes its place, as in MAME), {bad} otherwise")
    for t0, nb, nw, j, g, w in first_bad:
        print(f"   not at {t0 / 1e6:.4f} s: {nb} bytes, {nw} values, the same for {j}, then {g} against {w}")
    if n12:
        print(f"   {over10} of {n12} decoded samples ({100 * over10 / n12:.2f} %) lie outside 10 bits, where MAME's limit cuts them")

    # MAME's own samples against its bytes, 10-bit limited
    ok = array('f')
    with open(os.path.join(md, 'okim6258.f32'), 'rb') as f:
        ok.frombytes(f.read())
    mvals = [round(v * 2048) for v in ok]
    for k, (_, data, _) in enumerate(mp[:3]):
        w10 = decode(data, 512)
        # a sample a nibble: find where the play's first values stand in MAME's samples
        head = w10[:64]
        at = next((i for i in range(len(mvals) - 64) if mvals[i:i + 64] == head), None)
        if at is None:
            print(f"   MAME play {k}: its bytes' first values, decoded with a 10-bit limit, aren't in its samples")
            continue
        j = same_run(mvals[at:], w10)
        w12 = decode(data, 2048)
        print(f"   MAME play {k}: its {len(w10)} samples are its bytes decoded with a 10-bit limit for the first {j}"
              f"{' (all)' if j == len(w10) else ''}; with the board's 12 bits, {same_run(mvals[at:], w12)}")

    # ---------------------------------------------------------------- levels
    fm = array('h')
    with open(os.path.join(sd, 'fm.s16'), 'rb') as f:
        fm.frombytes(f.read())
    ym = array('f')
    with open(os.path.join(md, 'ym2151.f32'), 'rb') as f:
        ym.frombytes(f.read())
    if offs:
        m0, m1 = offs[0][0], offs[-1][0]
        d = offs[len(offs) // 2][1]
        a0, a1 = int(m0 / 1e6 * 62500), int(m1 / 1e6 * 62500)
        b0, b1 = int((m0 + d) / 1e6 * 62500), int((m1 + d) / 1e6 * 62500)
        for ch, nm in ((0, 'L'), (1, 'R')):
            rm = rms([v * 32768 for v in ym[2 * a0 + ch:2 * a1 + ch:2]])
            rs = rms(fm[2 * b0 + ch:2 * b1 + ch:2])
            print(f"\nFM level {nm}, {m0 / 1e6:.1f} to {m1 / 1e6:.1f} s of MAME's: simulation {rs:.0f}, MAME {rm:.0f} (of 32768): "
                  f"{20 * math.log10(rs / rm) if rm and rs else float('nan'):+.2f} dB", end='')
        print()
    (sl, sr), srate = wav(os.path.join(sd, 'audio.wav'))
    mch, mrate = wav(os.path.join(md, 'mix.wav'))          # MAME 0.289 writes the speaker's two and four silent
    ml, mr = mch[0], mch[1]
    if offs:
        d = offs[len(offs) // 2][1]
        for nm, s, m in (('L', sl, ml), ('R', sr, mr)):
            a = m[int(m0 / 1e6 * mrate):int(m1 / 1e6 * mrate)]
            b = s[int((m0 + d) / 1e6 * srate):int((m1 + d) / 1e6 * srate)]
            print(f"the mix {nm} over the same: simulation {rms(b):.0f}, MAME {rms(a):.0f}, peak {max(map(abs, b), default=0)} against {max(map(abs, a), default=0)}")


if __name__ == '__main__':
    main()
