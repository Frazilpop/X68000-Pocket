#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""What only the shell does, through the real core_top in the simulation, each with its own short run:
the save slot both ways, a missing save, the menu's pause, Reset, and a disk going into a drive.

    bash sim/gradius/build.sh port
    python3 -I sim/gradius/shell_test.py [name ...]

Each says what it saw; the first failure stops it. About twenty minutes for all of them on one core.
"""
import json, os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RUN = os.path.join(ROOT, 'build/sim/port/run')
OUT = os.path.join(ROOT, 'build/sim/shell')
DISK = os.path.join(ROOT, 'build/pocket/bublbobl_1.dim')
# While the boot ROM loads, the scan-out runs the bars on a raster of its own, and those frames count: at --rom-us 50 the load
# takes about 18. So every frame below is L on from the machine's own start, and each run checks the load was over by then.
L = 24
def F(n):
    return n + L

def run(name, *args):
    out = os.path.join(OUT, name)
    os.makedirs(out, exist_ok=True)
    p = subprocess.run([RUN, '--out', out, '--rom-us', '50', '--trace', out + '/bus.txt', '--trace-max', '3000000', *map(str, args)],
                       capture_output=True, text=True, cwd=ROOT)
    open(out + '/log.txt', 'w').write(p.stdout + p.stderr)
    if p.returncode:
        sys.exit(f'{name}: the run failed\n{p.stdout[-800:]}{p.stderr[-800:]}')
    frames = [l.split() for l in open(out + '/frames.txt')]
    if len(frames) >= L and not int(frames[L - 1][7], 16) & 0x10:
        sys.exit(f'{name}: the boot ROM was still loading at frame {L}: raise L')
    return out, frames, json.load(open(out + '/run.json')), p.stdout

def trace(out):
    for line in open(out + '/bus.txt'):
        p = line.split()
        yield int(p[0], 16), p[1], int(p[2], 16), int(p[3], 16)

def check(ok, what):
    print(('  ok   ' if ok else '  FAIL ') + what)
    if not ok:
        sys.exit(1)

def default_sram():
    """The machine's SRAM as the core seeds it, in the machine's byte order: as a save file."""
    words = {}
    for line in open(os.path.join(ROOT, 'rtl/diskemu/sramdefault.hex')):
        line = line.strip()
        if line.startswith(':'):
            b = bytes.fromhex(line[1:])
            if b[3] == 0:
                words[(b[1] << 8) | b[2]] = (b[5], b[4])   # the file's low byte is the word's first
    return b''.join(bytes(words.get(i, (0, 0))) for i in range(8192))

def t_save():
    print('save: a file in, read by the machine, and back out')
    sav = bytearray(default_sram())
    for i in range(0x1000, 0x4000):
        sav[i] = (i * 7 + (i >> 8)) & 255
    path = os.path.join(OUT, 'in.sav'); open(path, 'wb').write(sav)
    outp = os.path.join(OUT, 'out.sav')
    out, frames, j, log = run('save', '--frames', F(6), '--sav-in', path, '--sav-out', outp)
    check('the table says the save is 16384' in log, 'the table holds the save size')
    first = next((x for x in trace(out) if 0xed0000 <= x[0] < 0xed4000 and x[1] == 'R'), None)
    check(first is not None, f'the machine reads its SRAM: {first and hex(first[0])}')
    want = (sav[first[0] - 0xed0000] << 8) | sav[first[0] - 0xed0000 + 1]
    check(first[2] & first[3] == want & first[3], f'and gets the file\'s word: {first[2]:04x} of {want:04x} under {first[3]:04x}')
    written = {}
    for a, rw, d, m in trace(out):
        if rw == 'W' and 0xed0000 <= a < 0xed4000:
            k = a - 0xed0000
            if m & 0xff00: written[k] = d >> 8
            if m & 0x00ff: written[k + 1] = d & 255
    back = open(outp, 'rb').read()
    want_back = bytearray(sav)
    for k, v in written.items():
        want_back[k] = v
    wrong = [i for i in range(16384) if back[i] != want_back[i]]
    check(len(back) == 16384 and not wrong, f'the file comes back, with the {len(written)} bytes the machine wrote, not rotated' + (f': first wrong at {wrong[0]:x}' if wrong else ''))

def t_nosave():
    print('no save file: the core still has one to give back')
    outp = os.path.join(OUT, 'out2.sav')
    out, frames, j, log = run('nosave', '--frames', F(3), '--sav-out', outp)
    check('the table says the save is 16384' in log, 'the core has put the size in the table')
    back = open(outp, 'rb').read()
    d = default_sram()
    check(back[:8] == d[:8], f'it starts as the seed: {back[:8].hex()}')

def t_pause():
    print('pause: the menu stops the machine and blacks the picture')
    out, frames, j, log = run('pause', '--frames', F(24), '--menu', f'{F(10)}:1', '--menu', f'{F(18)}:0', '--every', 1)
    by = {int(f[0]): f for f in frames}
    a, b = int(by[F(12)][6]), int(by[F(17)][6])
    check(a == b, f'no bus access from frame {F(12)} to {F(17)} of the menu: {a} and {b}')
    check(int(by[F(23)][6]) > b, f'and it goes on after: {by[F(23)][6]}')
    check(by[F(12)][4] == by[F(17)][4], 'the menu\'s frames are alike')

def t_reset():
    print('reset: Core Settings\' Reset starts the IPL again, with the ROM still there')
    out, frames, j, log = run('reset', '--frames', F(16), '--reset', F(8))
    starts = [i for i, x in enumerate(trace(out)) if x[0] == 0 and x[1] == 'R']
    tr = list(trace(out))
    vec = [i for i in range(len(tr) - 3) if tr[i][:3] == (0, 'R', 0) and tr[i + 1][:3] == (2, 'R', 0x2000)]
    check(len(vec) >= 2, f'the reset vector is read at {vec[:3]}')
    n = min(4000, len(tr) - vec[-1])
    same = sum(1 for k in range(n) if tr[vec[0] + k] == tr[vec[-1] + k])
    check(same == n, f'the first {n} accesses after it are as they were at power-on ({same} alike)')

def black(path):
    sys.path.insert(0, os.path.join(ROOT, 'tools/pocket'))
    sys.dont_write_bytecode = True
    import match_frames
    w, h, rows = match_frames.png(path)
    return all(not any(r) for r in rows)

def t_mount():
    print('mount: no disk, then disk 1 chosen in the menu; then the menu over a picture')
    out, frames, j, log = run('mount', '--frames', F(300), '--disk', 1, DISK, '--drive0', '0:7', '--drive0', f'{F(100)}:0',
                              '--menu', f'{F(285)}:1', '--menu', f'{F(293)}:0', '--save', f'{F(284)},{F(290)},{F(299)}')
    apf = open(out + '/apf.log').read().splitlines()
    disk = [l for l in apf if ' id 10 ' in l]
    check(disk, f'the disk is read: {len(disk)} sectors')
    first = int(disk[0].split('frame')[1])
    check(first >= F(100), f'and not before it was chosen: the first at frame {first}')
    check(j['cmds_failed'] == 0, 'no command came back with an error')
    check(not black(out + f'/f_{F(284):05d}.png'), 'there is a picture before the menu')
    check(black(out + f'/f_{F(290):05d}.png'), 'black under the menu')
    check(not black(out + f'/f_{F(299):05d}.png'), 'and the picture is back after it')
    by = {int(f[0]): f for f in frames}
    check(by[F(287)][6] == by[F(292)][6], f'the machine stood still: {by[F(287)][6]} and {by[F(292)][6]} accesses')

TESTS = {'save': t_save, 'nosave': t_nosave, 'pause': t_pause, 'reset': t_reset, 'mount': t_mount}
if __name__ == '__main__':
    os.makedirs(OUT, exist_ok=True)
    for n in sys.argv[1:] or TESTS:
        TESTS[n]()
    print('all as they should be')
