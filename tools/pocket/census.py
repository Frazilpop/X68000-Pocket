#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# X68000 for the Analogue Pocket
"""Turn tools/mame_x68k_census.lua's logs into modes, pages and PSRAM fetch figures.

    python3 -I tools/pocket/census.py build/mame/census/*.log

For each log, the video modes the program held for at least two whole frames
(dots, raster lines, kHz, Hz, the box upstream's x68k_video_window would give it)
and, within each, what the graphics pages asked of memory:

  bursts  16-word PSRAM bursts a line would cost if only the visible dots are
          fetched: for each page shown, the 16-word blocks its visible window
          falls in, with pages on the same row and blocks in common counted once.
  fill    the bursts' time as a share of the time there is to fetch that line:
          one raster line, or two when the mode double-scans. A burst is
          BURST_US, as Cave's core has it at 40 MHz.
  held    a figure kept up for SUSTAINED raster lines or more, which is what a
          line store has to carry; "peak" counts any line at all, such as the one
          where a game's write of a second scroll register hasn't happened yet.
  chip    a frame's whole use of a PSRAM: the display's worst held line for every
          line, plus the bus accesses (CPU and DMA) at CPU_US each, which is a
          figure assumed from the burst's overhead and not measured.

--summary leaves out the per-mode lines and ends with the boxes across all the logs.

Which page a line shows follows MAME's reading of the video controller
(x68k_v.cpp): register 2's bit n turns on the page at priority n, register 1 gives
the order, register 0 the colours. 256 colours shows a page and the next as one.
"""

import argparse
import collections
import os
import sys

BURST_US = 0.55                    # 16 words in 22 clocks at 40 MHz
CPU_US = 0.3                       # one word; not measured
SUSTAINED = 4                      # raster lines

CLOCK_15K = 38.86363
CLOCK_31K = 69.55199
CLOCK_50M = 50.35
RESET = {0: 137, 1: 14, 2: 28, 3: 124, 4: 567, 5: 5, 6: 40, 7: 552, 8: 27, 20: 0x316}


def dot_clock(r20, hrl):
    """MHz, as upstream's x68k_native_crtc.sv and x68k_video_clock.sv have it: MAME
    has no HRL, and it counts a line 8 dots short."""
    mode = (hrl << 3) | ((r20 >> 2) & 4) | (r20 & 3)
    base = CLOCK_50M if mode & 3 == 3 else CLOCK_31K if mode & 4 else CLOCK_15K
    if mode in (0, 2, 3, 8, 10, 11, 12):
        return base / 8
    if mode in (1, 9, 13):
        return base / 4
    return base / {4: 6, 5: 3}.get(mode, 2)


def box(r20, hrl, ht, hb, he, vb, ve, vt):
    """The box upstream's x68k_video_window.sv works out, in dots and lines."""
    hm, vm = r20 & 3, (r20 >> 2) & 3
    hf = (r20 >> 4) & 1
    is24 = hf and ((hm == 2 and ht >= 160) or
                   (hm == 1 and not hrl and ht >= 100) or (hm == 1 and hrl and ht >= 80) or
                   (hm == 0 and not hrl and ht >= 53) or (hm == 0 and hrl and 40 <= ht < 50))
    if hf:
        hn = {0: (30 if is24 else 48) if hrl else (40 if is24 else 32),
              1: (62 if is24 else 48) if hrl else (80 if is24 else 64)}.get(hm, 96)
    else:
        hn = {0: 48 if hrl else 32, 1: 64}.get(hm, 96)
    vn = 424 if is24 else 512 if hf else 256
    ha = (hb + 4) if hb + 4 <= ht else hb + 4 - ht - 1
    hz = (he + 4) if he + 4 <= ht else he + 4 - ht - 1
    span = hz - ha if hz >= ha else ht + 1 - ha + hz
    active_h = min(255, span) or 1
    active_v = (ve - vb) if ve > vb else 1
    w = min(max(active_h, hn), ht)
    h = min(max(active_v, vn), vt)
    return w * 8, h


def shown_pages(vc, regs):
    """[(page, x, y)] of what's on at this moment."""
    if regs.get(20, 0) & 0x800:         # graphics set to buffer: not displayed
        return []
    colours = vc.get(0, 0) & 3
    order = [(vc.get(1, 0) >> (2 * p)) & 3 for p in range(4)]
    on = vc.get(2, 0)
    pages = []
    for pri in range(4):
        if on & (1 << pri):
            page = order[pri]
            if colours == 0:
                pages.append(page)
            elif colours == 1:
                if page in (0, 2):
                    pages += [page, page + 1]
            else:
                pages.append(0)
    pages = sorted(set(pages))
    return [(p, regs.get(12 + 2 * p, 0) & 0x1ff, regs.get(13 + 2 * p, 0) & 0x1ff) for p in pages]


def bursts(pages, dots):
    """16-word bursts one line takes, and the distinct rows."""
    blocks = set()
    rows = set()
    for _, x, y in pages:
        rows.add(y)
        for d in range(0, max(dots, 1), 16):
            blocks.add((y, ((x + d) & 0x1ff) >> 4))
        blocks.add((y, ((x + dots - 1) & 0x1ff) >> 4))
    return len(blocks), len(rows)


class Mode:
    def __init__(self):
        self.frames = 0
        self.first = None
        self.fetch = collections.Counter()   # (bursts, rows, colours, pages) -> frames, held
        self.peak = None
        self.raster = 0                      # most scroll writes during the picture, a frame
        self.chip = (0, 0, 0)                # GVRAM's worst share, its display, its CPU
        self.text_chip = 0                   # TVRAM's worst share


MODE_REGS = (0, 1, 2, 3, 4, 5, 6, 7, 8, 20)


def mode_key(regs, hrl):
    return tuple(regs.get(n, 0) for n in MODE_REGS) + (hrl,)


def describe(key):
    ht, _, hb, he, vt, _, vb, ve, _, r20, hrl = key
    r = r20 & 0x1f
    htotal = (ht + 1) * 8
    khz = dot_clock(r20, hrl) * 1000 / htotal
    hz = khz * 1000 / (vt + 1)
    return dict(r20=r, dots=(he - hb) * 8, lines=ve - vb, htotal=htotal, vtotal=vt + 1,
                khz=khz, hz=hz, dbl=(r20 & 0x1e) == 0x10,
                box=box(r20, hrl, ht, hb, he, vb, ve, vt), hrl=hrl)


def analyse(path):
    regs, vc = dict(RESET), {}
    hrl = 0
    frames = {}
    counts = {}
    clears = copies = 0
    last_frame = 0
    with open(path) as f:
        for line in f:
            p = line.split()
            if not p:
                continue
            t = p[0]
            if t in ("R", "V", "H"):
                frames.setdefault(int(p[1]), []).append(p)
            elif t == "O":
                v = int(p[3])
                clears += (v >> 1) & 1
                copies += v & 1
            elif t == "C":                 # written at the frame's end: its writes are n - 1
                n = int(p[1]) - 1
                counts[n] = tuple(int(x) for x in p[2:])
                last_frame = max(last_frame, n)
    modes = collections.OrderedDict()
    for n in range(0, last_frame + 1):
        writes = frames.get(n, [])
        start_key = mode_key(regs, hrl)
        vend, vbegin = regs.get(7, 552), regs.get(6, 40)
        vtotal = regs.get(4, 567) + 1
        visible_from = max(0, vtotal - (vend - vbegin) - 1)    # lines since vblank began
        held = None
        peak = None
        raster = 0

        def segment(t0, t1):
            nonlocal held, peak
            shown = min(t1, vtotal) - max(t0, visible_from)
            if shown <= 0:
                return
            pages = shown_pages(vc, regs)
            b, rows = bursts(pages, (regs.get(3, 0) - regs.get(2, 0)) * 8)
            rec = (b, rows, vc.get(0, 0) & 3, len(pages))
            if peak is None or rec > peak:
                peak = rec
            if shown >= SUSTAINED and (held is None or rec > held):
                held = rec

        last_t = 0
        for w in writes:
            t = (int(w[2]) - vend - 1) % vtotal
            segment(last_t, t)
            if w[0] == "R":
                regs[int(w[3])] = int(w[4])
                if 12 <= int(w[3]) <= 19 and t >= visible_from:
                    raster += 1
            elif w[0] == "V":
                vc[int(w[3])] = int(w[4])
            else:
                hrl = (int(w[3]) >> 1) & 1
            last_t = t
        segment(last_t, vtotal)
        if mode_key(regs, hrl) != start_key:
            continue                     # the mode moved during this frame
        m = modes.setdefault(start_key, Mode())
        m.frames += 1
        if m.first is None:
            m.first = n
        if held is not None:
            m.fetch[held] += 1
        if peak is not None and (m.peak is None or peak > m.peak):
            m.peak = peak
        m.raster = max(m.raster, raster)
        d = describe(start_key)
        line_us = 1000 / d["khz"]
        frame_us = line_us * d["vtotal"]
        c = counts.get(n, (0, 0, 0, 0))
        lines = d["lines"] / (2 if d["dbl"] else 1)
        video = (held[0] if held else 0) * BURST_US * lines / frame_us
        cpu = (c[0] + c[1]) * CPU_US / frame_us
        if video + cpu > sum(m.chip[1:]):
            m.chip = (video + cpu, video, cpu)
        text_on = vc.get(2, 0) & 0x20
        words = d["dots"] // 16 * 4 if text_on else 0
        text = (words / 16 * BURST_US * d["lines"] + (c[2] + c[3]) * CPU_US) / frame_us
        m.text_chip = max(m.text_chip, text)
    return modes, counts, last_frame, clears, copies


def colours(c):
    return {0: "16", 1: "256"}.get(c, "64k")


MIN_FRAMES = 30                    # shorter than this is a program on its way somewhere


def report(path, summary):
    modes, counts, last, clears, copies = analyse(path)
    name = os.path.splitext(os.path.basename(path))[0]
    rows = []
    print(f"## {name}: {last} frames, {clears} fast clears, {copies} text raster copies")
    for key, m in modes.items():
        if m.frames < 2:
            continue
        d = describe(key)
        budget = (2 if d["dbl"] else 1) * 1000 / d["khz"]
        worst = max(m.fetch, default=None)
        fill = worst[0] * BURST_US / budget if worst else 0
        rows.append(dict(set=name, key=key, d=d, m=m, worst=worst, fill=fill, budget=budget))
        if summary and m.frames < MIN_FRAMES:
            continue
        print(f"  R20 {key[9]:04x}{' HRL' if key[10] else ''} {d['dots']}x{d['lines']} of "
              f"{d['htotal']}x{d['vtotal']} {d['khz']:.2f} kHz {d['hz']:.2f} Hz"
              f"{' double-scan' if d['dbl'] else ''} box {d['box'][0]}x{d['box'][1]}: "
              f"{m.frames} frames from {m.first}"
              f"{f', {m.raster} scroll writes in a picture' if m.raster else ''}")
        for (b, r, col, pages), n in sorted(m.fetch.items(), key=lambda kv: -kv[0][0])[:1 if summary else 99]:
            print(f"      held {colours(col):>3} colours, {pages} pages on {r} rows: {b:3d} bursts, "
                  f"{b * BURST_US:5.1f} us of {budget:5.1f} = {100 * b * BURST_US / budget:3.0f} %: {n} frames")
        if m.peak and m.peak != worst:
            b, r, col, pages = m.peak
            print(f"      peak {colours(col):>3} colours, {pages} pages on {r} rows: {b:3d} bursts, "
                  f"{100 * b * BURST_US / budget:3.0f} %")
        print(f"      chip: GVRAM's worst frame {100 * m.chip[0]:3.0f} % (display {100 * m.chip[1]:3.0f}, "
              f"bus {100 * m.chip[2]:3.0f}); TVRAM's {100 * m.text_chip:3.0f} %")
    if counts:
        gv = [c[0] + c[1] for c in counts.values()]
        tv = [c[2] + c[3] for c in counts.values()]
        print(f"  bus a frame: GVRAM mean {sum(gv) // len(gv)}, peak {max(gv)}; "
              f"TVRAM mean {sum(tv) // len(tv)}, peak {max(tv)}")
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("logs", nargs="+")
    ap.add_argument("--summary", action="store_true")
    a = ap.parse_args()
    rows = []
    for p in a.logs:
        rows += report(p, a.summary)
    boxes = collections.defaultdict(lambda: dict(frames=0, sets=set(), khz=set()))
    for r in rows:
        if r["m"].frames >= MIN_FRAMES:
            b = boxes[r["d"]["box"]]
            b["frames"] += r["m"].frames
            b["sets"].add(r["set"].replace("_play", ""))
            b["khz"].add(f"{r['d']['khz']:.2f} kHz {r['d']['hz']:.2f} Hz")
    print("## boxes")
    for k, b in sorted(boxes.items(), key=lambda kv: -kv[1]["frames"]):
        print(f"  {k[0]}x{k[1]}: {b['frames']} frames, {', '.join(sorted(b['khz']))}: "
              f"{', '.join(sorted(b['sets']))}")
    print("## worst held lines")
    for r in sorted((r for r in rows if r["worst"]), key=lambda r: -r["fill"])[:12]:
        print(f"  {100 * r['fill']:3.0f} % {r['set']}: {r['d']['dots']}x{r['d']['lines']} "
              f"{r['d']['khz']:.2f} kHz, {colours(r['worst'][2])} colours, {r['worst'][1]} rows, "
              f"{r['worst'][0]} bursts, {r['m'].fetch[r['worst']]} frames")
    print("## worst chips")
    for r in sorted(rows, key=lambda r: -r["m"].chip[0])[:6]:
        m = r["m"]
        print(f"  GVRAM {100 * m.chip[0]:3.0f} % (display {100 * m.chip[1]:3.0f}, bus "
              f"{100 * m.chip[2]:3.0f}) {r['set']}: {r['d']['dots']}x{r['d']['lines']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
