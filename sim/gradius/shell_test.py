#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""What only the shell does, through the real core_top in the simulation, each with its own short run:
the save slot both ways, a missing save, the menu's pause, Reset, a disk going into a drive, a program's write
reaching the file, a drive changed under the menu, the boot disk found by HUMAN.SYS, a game with no disk, a raw XDF, a disk going back into a drive the program ejected, the set's next file
going in by itself (the motor off, or left on 5 s, or between a program's ejects), the game loaded again with the core kept, a card command the Pocket drops, the keyboard's F1 and rapid shot, and the screen before the boot ROM is in (black, the
overlay's bars, or BOOT ROM NOT FOUND).

    bash sim/gradius/build.sh port
    python3 -I sim/gradius/shell_test.py [name ...]

Each says what it saw; the first failure stops it. About fifty minutes for all of them on one core.
"""
import json, os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RUN = os.path.join(ROOT, os.environ.get('SIM_RUN', 'build/sim/port/run'))
OUT = os.path.join(ROOT, 'build/sim/shell')
DISK = os.path.join(ROOT, 'build/pocket/bublbobl_1.dim')
# While the boot ROM loads, the scan-out runs the bars on a raster of its own, and those frames count: at --rom-us 50 the load
# takes about 18. So every frame below is L on from the machine's own start, and each run checks the load was over by then.
L = 24
def F(n):
    return n + L

def run(name, *args, loaded=True):
    out = os.path.join(OUT, name)
    os.makedirs(out, exist_ok=True)
    p = subprocess.run([RUN, '--out', out, '--rom-us', '50', '--trace', out + '/bus.txt', '--trace-max', '3000000', *map(str, args)],
                       capture_output=True, text=True, cwd=ROOT)
    open(out + '/log.txt', 'w').write(p.stdout + p.stderr)
    split_scan(out)
    if p.returncode:
        sys.exit(f'{name}: the run failed\n{p.stdout[-800:]}{p.stderr[-800:]}')
    frames = [l.split() for l in open(out + '/frames.txt')]
    if loaded and len(frames) >= L and not int(frames[L - 1][7], 16) & 0x10:
        sys.exit(f'{name}: the boot ROM was still loading at frame {L}: raise L')
    return out, frames, json.load(open(out + '/run.json')), p.stdout

def split_scan(out):
    """The boot disk's look into each disk's root directory, made during the load, goes to scan.log, so apf.log holds
    the boot ROM and the machine's own reads as before."""
    path = out + '/apf.log'
    if not os.path.exists(path):
        return
    keep, scan = [], []
    for l in open(path).read().splitlines():
        p = l.split()
        sc = ('id' in p and int(p[p.index('id') + 1]) >= 10 and p[p.index('len') + 1] == '512'
              and p[p.index('off') + 1] in ('5120', '5376') and int(p[p.index('frame') + 1]) < L)
        (scan if sc else keep).append(l)
    open(path, 'w').write(''.join(l + '\n' for l in keep))
    open(out + '/scan.log', 'w').write(''.join(l + '\n' for l in scan))

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

def boots(body):
    """A disk's body with HUMAN.SYS in its root directory, as a Human68k disk has it, so the core takes it for the
    set's boot disk; the tests' own disks boot from their boot sector and would otherwise lose drive 0 to bublbobl's."""
    body[0x1400:0x140B] = b'HUMAN   SYS'
    return body

def t_save():
    print('save: a file in, read by the machine, and back out')
    sav = bytearray(default_sram())
    for i in range(0x1000, 0x4000):
        sav[i] = (i * 7 + (i >> 8)) & 255
    path = os.path.join(OUT, 'in.sav'); open(path, 'wb').write(sav)
    outp = os.path.join(OUT, 'out.sav')
    out, frames, j, log = run('save', '--frames', F(6), '--disk', 1, DISK, '--sav-in', path, '--sav-out', outp)
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
    out, frames, j, log = run('nosave', '--frames', F(3), '--disk', 1, DISK, '--sav-out', outp)
    check('the table says the save is 16384' in log, 'the core has put the size in the table')
    back = open(outp, 'rb').read()
    d = default_sram()
    check(back[:8] == d[:8], f'it starts as the seed: {back[:8].hex()}')

def t_pause():
    print('pause: the menu stops the machine and blacks the picture')
    out, frames, j, log = run('pause', '--frames', F(24), '--disk', 1, DISK, '--menu', f'{F(10)}:1', '--menu', f'{F(18)}:0', '--every', 1)
    by = {int(f[0]): f for f in frames}
    a, b = int(by[F(12)][6]), int(by[F(17)][6])
    check(a == b, f'no bus access from frame {F(12)} to {F(17)} of the menu: {a} and {b}')
    check(int(by[F(23)][6]) > b, f'and it goes on after: {by[F(23)][6]}')
    check(by[F(12)][4] == by[F(17)][4], 'the menu\'s frames are alike')

def t_reset():
    print('reset: Core Settings\' Reset starts the IPL again, with the ROM still there')
    out, frames, j, log = run('reset', '--frames', F(16), '--disk', 1, DISK, '--reset', F(8))
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

def write_disk(path):
    """A disk whose boot sector writes itself, 1024 bytes, onto the disk's last sector with IOCS _B_WRITE, then
    loops. MAME 0.289 issues the one WRITE DATA (C 76, H 1, R 8) at its frame 123 and ends normally. The sector
    sits 256 bytes off the 512-byte grid (the DIM's header), so three blocks change, the last cut short by the
    file's end, and the program never asks for another."""
    hdr = bytearray(256)
    hdr[1:0x9B] = b'\x01' * 154
    hdr[0xAB:0xB8] = b'DIFC HEADER  '
    hdr[0xFE] = 0x16
    boot = bytearray((i * 7 + (i >> 8)) & 255 for i in range(1024))
    boot[0:2] = bytes.fromhex('601e')                                   # bra.s $2020: the IPL wants a branch first
    code = bytes.fromhex('7045'             # moveq  #$45,d0         _B_WRITE
                         '323c9070'         # move.w #$9070,d1       2HD, drive 0
                         '243c034c0108'     # move.l #$034C0108,d2   1024 bytes a sector, C 76 H 1 R 8
                         '263c00000400'     # move.l #$400,d3
                         '43f900002000'     # lea    $2000,a1        this sector, as loaded
                         '4e4f'             # trap   #15
                         '60fe')            # bra.s  *
    boot[0x20:0x20 + len(code)] = code
    body = boots(bytearray(154 * 8 * 1024))
    body[:1024] = boot
    open(path, 'wb').write(hdr + body)
    return bytes(hdr + body)

def t_write():
    print('write: a program\'s write reaches the file; a drive changed under the menu waits for it to close')
    path = os.path.join(OUT, 'wtest.dim')
    disk = write_disk(path)
    out, frames, j, log = run('write', '--frames', F(140), '--disk', 1, path, '--disk', 2, DISK,
                              '--menu', f'{F(120)}:1', '--drive1', f'{F(122)}:7', '--menu', f'{F(130)}:0')
    apf = open(out + '/apf.log').read().splitlines()
    wr = [l.split() for l in apf if l.split()[1] == '0184']
    last = len(disk) - 1024                       # the last sector: after the header, 256 bytes off the 512-byte grid
    blocks = list(range(last - last % 512, len(disk), 512))
    check(sorted(int(w[5]) for w in wr) == blocks, f'the blocks it spans written, once each: {[w[5] + "+" + w[7] for w in wr]}')
    back = open(out + '/disk_1.dim', 'rb').read()
    check(back[last:] == disk[256:256 + 1024], 'the last sector holds the boot sector, as MAME writes it')
    check(back[:last] == disk[:last], 'and nothing else changed')
    check(j['cmds_failed'] == 0, 'no command came back with an error')
    by = {int(f[0]): int(f[7], 16) for f in frames}
    check(by[F(119)] & 0x1800 == 0x1800, f'both drives hold a disk before the menu: flags {by[F(119)]:04x}')
    check(by[F(128)] & 0x1000, f'drive 1 still holds its disk with the menu open after the change: flags {by[F(128)]:04x}')
    check(not by[F(135)] & 0x1000 and by[F(135)] & 0x0800, f'and is empty once it has closed, drive 0 untouched: flags {by[F(135)]:04x}')

def swap_disk(path, motor=False):
    """A disk whose boot sector does what sf2ce does at its "set disk 2": reads drive 1 (IOCS _B_READ, C 0 H 0 R 1),
    ejects drive 1 itself (E94005 = $22 then $20), polls E94005 with drive 1 selected ($82, read, $80) until the
    disk-in bit comes back, then writes $5A to SRAM's ED3FF0 and loops. MAME 0.289: the read at its frame 110, the eject
    at 119, and bit 7 back at 150, the frame the plan puts a disk in. With motor, the loop turns the drive motor on
    (E94007 = $80) every time round, so it stays on while the program waits, as Overtake's does."""
    hdr = bytearray(256)
    hdr[1:0x9B] = b'\x01' * 154
    hdr[0xAB:0xB8] = b'DIFC HEADER  '
    boot = bytearray(1024)
    boot[0:2] = bytes.fromhex('601e')                                   # bra.s $2020
    read1 = ('7046'                     # moveq  #$46,d0         _B_READ
             '323c9170'                 # move.w #$9170,d1       2HD, drive 1
             '243c03000001'             # move.l #$03000001,d2   1024 bytes a sector, C 0 H 0 R 1
             '263c00000400'             # move.l #$400,d3
             '43f9{:08x}'               # lea    buf,a1
             '4e4f')                    # trap   #15
    code = bytes.fromhex(read1.format(0x3000) +
                         '13fc002200e94005'     # move.b #$22,$E94005   drive 1, eject
                         '13fc002000e94005' +   # move.b #$20,$E94005   its select falls: the eject
                         ('13fc008000e94007' if motor else '') +    # loop: move.b #$80,$E94007   the motor on
                         '13fc008200e94005'     # move.b #$82,$E94005
                         '103900e94005'         # move.b $E94005,d0     bit 7: a disk in
                         '13fc008000e94005'     # move.b #$80,$E94005
                         '4a00' +               # tst.b  d0
                         ('6ade' if motor else '6ae6') +            # bpl.s  loop
                         '13fc003100e8e00d'     # move.b #$31,$E8E00D   SRAM writable
                         '13fc005a00ed3ff0'     # move.b #$5A,$ED3FF0
                         '60fe')                # bra.s  *
    boot[0x20:0x20 + len(code)] = code
    body = boots(bytearray(154 * 8 * 1024))
    body[:1024] = boot
    open(path, 'wb').write(hdr + body)

def eject_disk(path, again=False):
    """A disk whose boot sector waits for its next disk as Garou Densetsu Special does: reads drive 1, ejects it, and
    then, the motor on, ejects the empty drive again every second by the IPL's clock (IOCS _ONTIME, hundredths), d7
    counting the ejects, until a disk is in; then writes $5A to SRAM's ED3FF0, d7 to ED3FF2 and the hundredths from
    the last eject to the disk to ED3FF4, and loops. With again, the first disk that comes in is ejected too and
    waited out the same way (Garou wanting an earlier disk back), and only the second counts."""
    hdr = bytearray(256)
    hdr[1:0x9B] = b'\x01' * 154
    hdr[0xAB:0xB8] = b'DIFC HEADER  '
    boot = bytearray(1024)
    boot[0:2] = bytes.fromhex('601e')                                   # bra.s $2020
    eject = '13fc002200e94005' '13fc002000e94005'                      # drive 1 selected, then its select falls, bit 5 set
    ontime = '707f' '4e4f'                                              # moveq #$7F,d0; trap #15: d0 the time, hundredths
    parts = [('read', '7a00'                                            # moveq #0,d5: the disks that came in
                      '7046' '323c9170' '243c03000001' '263c00000400' '43f900003000' '4e4f'),   # _B_READ drive 1, C 0 H 0 R 1
             ('eject', eject + '7e00'),                                 # moveq #0,d7
             ('outer', ontime + '2c00'),                                # move.l d0,d6: when it ejected
             ('inner', '13fc008000e94007'                                # the motor on, every poll
                       '13fc008200e94005' '183900e94005' '13fc008000e94005' '4a04'),   # d4: bit 7, a disk in
             ('bmi', '6b{found}'),
             ('clock', ontime + '9086' '0c8000000064'),                  # sub.l d6,d0; cmpi.l #100,d0
             ('bcs', '65{inner}'),                                      # under a second: poll again
             ('again', '5247' + eject),                                 # addq.w #1,d7; eject again
             ('bra', '60{outer}'),
             ('found', ontime + '9086')]                                 # the time since the last eject
    if again:
        parts += [('tst', '4a45'),                                      # tst.w d5: (a branch starts its part)
                  ('bne', '66{fin}'),                                   # bne.s fin
                  ('first', '5245' + eject + '7e00'),                   # addq.w #1,d5; eject it too; moveq #0,d7
                  ('bra2', '60{outer}')]
    parts += [('fin', '13fc003100e8e00d' '13fc005a00ed3ff0' '33c700ed3ff2' '23c000ed3ff4' '60fe')]
    at, pc = {}, 0x2020
    T = ('found', 'inner', 'outer', 'fin')
    for name, h in parts:
        at[name] = pc
        for t in T:
            h = h.replace('{' + t + '}', '00')
        pc += len(h) // 2
    code = ''
    for name, h in parts:
        for t in T:
            if '{' + t + '}' in h:
                d = at[t] - (at[name] + 2)
                assert -128 <= d < 128 and d != 0
                h = h.replace('{' + t + '}', f'{d & 255:02x}')
        code += h
    boot[0x20:0x20 + len(code) // 2] = bytes.fromhex(code)
    body = boots(bytearray(154 * 8 * 1024))
    body[:1024] = boot
    open(path, 'wb').write(hdr + body)

def t_swap():
    print('swap: a program ejects drive 1 and waits; a file chosen in the menu goes in, and is read')
    path = os.path.join(OUT, 'stest.dim')
    swap_disk(path)
    other = os.path.join(ROOT, 'build/pocket/sf2ce_3.dim')
    outp = os.path.join(OUT, 'swap.sav')
    out, frames, j, log = run('swap', '--frames', F(260), '--disk', 1, path, '--disk', 2, DISK, '--disk', 3, other,
                              '--menu', f'{F(150)}:1', '--drive1', f'{F(152)}:2', '--menu', f'{F(160)}:0', '--sav-out', outp)
    apf = [l.split() for l in open(out + '/apf.log').read().splitlines()]
    ids = [(l[l.index('id') + 1], int(l[l.index('frame') + 1])) for l in apf if 'id' in l and 'frame' in l]
    before = [f for i, f in ids if i == '11']
    after = [f for i, f in ids if i == '12']
    check(before and max(before) < F(150), f'drive 1\'s first file is read before the menu: frames {before[:3]}')
    check(after, f'the file chosen in the menu is read: frames {after[:3]}')
    check(min(after) > F(160), f'and not before the menu closed: frame {min(after)}')
    back = open(outp, 'rb').read()
    check(0x5A in back[0x3FF0:0x3FF2], f'the program saw the disk go in: SRAM ED3FF0 {back[0x3FF0:0x3FF2].hex()}')
    check(j['cmds_failed'] == 0, 'no command came back with an error')

def t_autoswap():
    print('autoswap: a program ejects drive 1 and waits; with no menu the set\'s next file goes in once the motor is off, and Reset puts the first back')
    path = os.path.join(OUT, 'stest.dim')
    swap_disk(path)
    other = os.path.join(ROOT, 'build/pocket/sf2ce_3.dim')
    outp = os.path.join(OUT, 'autoswap.sav')
    # Reset with the menu closed: under it the machine stands still with its CRTC cleared, so no frame ends, and this
    # harness closes its menu on a frame count
    out, frames, j, log = run('autoswap', '--frames', F(600), '--disk', 1, path, '--disk', 2, DISK, '--disk', 3, other,
                              '--reset', F(430), '--sav-out', outp)
    apf = [l.split() for l in open(out + '/apf.log').read().splitlines()]
    ids = [(l[l.index('id') + 1], int(l[l.index('frame') + 1])) for l in apf if 'id' in l and 'frame' in l]
    by = {int(f[0]): f for f in frames}
    motor_off = [n for n in sorted(by) if n > F(100) and not int(by[n][7], 16) & 0x4000 and int(by[n - 1][7], 16) & 0x4000]
    first = [f for i, f in ids if i == '11' and f < F(420)]
    nxt = [f for i, f in ids if i == '12']
    again = [f for i, f in ids if i == '11' and f > F(430)]
    check(first, f'drive 1\'s first file is read: frames {first[:3]}')
    check(nxt, f'the next file goes in by itself and is read: frames {nxt[:3]}')
    check(motor_off and min(nxt) > motor_off[0] + 50, f'a second and more after the motor stopped at frame {motor_off[:1]}: read at {min(nxt)}')
    check(max(nxt) < F(420), 'and nothing of it after the reset')
    check(again, f'after Reset drive 1 holds its first file again: read at {again[:3]}')
    back = open(outp, 'rb').read()
    check(0x5A in back[0x3FF0:0x3FF2], f'the program saw the disk go in: SRAM ED3FF0 {back[0x3FF0:0x3FF2].hex()}')
    check(j['cmds_failed'] == 0, 'no command came back with an error')

def t_autoswap_on():
    print('autoswap_on: a program ejects drive 1 and waits with the motor on; the set\'s next file goes in by itself after 5 s')
    path = os.path.join(OUT, 'stest_on.dim')
    swap_disk(path, motor=True)
    other = os.path.join(ROOT, 'build/pocket/sf2ce_3.dim')
    outp = os.path.join(OUT, 'autoswap_on.sav')
    out, frames, j, log = run('autoswap_on', '--frames', F(560), '--disk', 1, path, '--disk', 2, DISK, '--disk', 3, other,
                              '--sav-out', outp)
    apf = [l.split() for l in open(out + '/apf.log').read().splitlines()]
    ids = [(l[l.index('id') + 1], int(l[l.index('frame') + 1])) for l in apf if 'id' in l and 'frame' in l]
    by = {int(f[0]): f for f in frames}
    first = [f for i, f in ids if i == '11']
    nxt = [f for i, f in ids if i == '12']
    check(first, f'drive 1\'s first file is read: frames {first[:3]}')
    check(nxt, f'the next file goes in by itself and is read: frames {nxt[:3]}')
    off = [n for n in sorted(by) if max(first) < n < min(nxt) and not int(by[n][7], 16) & 0x4000]
    check(not off, f'the motor on from the first read to the next file\'s: off at {off[:3]}')
    check(min(nxt) - max(first) > 250, f'after 5 s and more: {max(first)} to {min(nxt)}')
    back = open(outp, 'rb').read()
    check(0x5A in back[0x3FF0:0x3FF2], f'the program saw the disk go in: SRAM ED3FF0 {back[0x3FF0:0x3FF2].hex()}')
    check(j['cmds_failed'] == 0, 'no command came back with an error')

def t_autoswap_eject():
    print('autoswap_eject: a program ejects drive 1 and goes on ejecting it, empty, every second with the motor on; the next file lands mid-way between two ejects')
    path = os.path.join(OUT, 'stest_ej.dim')
    eject_disk(path)
    other = os.path.join(ROOT, 'build/pocket/sf2ce_3.dim')
    outp = os.path.join(OUT, 'autoswap_eject.sav')
    out, frames, j, log = run('autoswap_eject', '--frames', F(620), '--disk', 1, path, '--disk', 2, DISK, '--disk', 3, other,
                              '--sav-out', outp)
    apf = [l.split() for l in open(out + '/apf.log').read().splitlines()]
    ids = [(l[l.index('id') + 1], int(l[l.index('frame') + 1])) for l in apf if 'id' in l and 'frame' in l]
    first = [f for i, f in ids if i == '11']
    nxt = [f for i, f in ids if i == '12']
    check(first, f'drive 1\'s first file is read: frames {first[:3]}')
    check(nxt, f'the next file goes in by itself and is read: frames {nxt[:3]}')
    back = open(outp, 'rb').read()
    check(0x5A in back[0x3FF0:0x3FF2], f'the program saw the disk go in: SRAM ED3FF0 {back[0x3FF0:0x3FF2].hex()}')
    ejects, cs = int.from_bytes(back[0x3FF2:0x3FF4], 'big'), int.from_bytes(back[0x3FF4:0x3FF8], 'big')
    check(ejects >= 4, f'after 5 s and more of ejects: {ejects} after the first')
    check(40 <= cs <= 65, f'mid-way between two: {cs / 100:.2f} s after the last (0.1 s, then the disk emulation\'s 0.4 s)')
    check(j['cmds_failed'] == 0, 'no command came back with an error')

def t_autoswap_wrap():
    print('autoswap_wrap: a program ejects the next file too and waits on; past the set\'s last file the swap goes round to its first, passing the file in drive 0 and the one just ejected')
    path = os.path.join(OUT, 'stest_wrap.dim')
    eject_disk(path, again=True)
    other = os.path.join(ROOT, 'build/pocket/sf2ce_3.dim')
    outp = os.path.join(OUT, 'autoswap_wrap.sav')
    out, frames, j, log = run('autoswap_wrap', '--frames', F(1000), '--disk', 1, path, '--disk', 2, DISK, '--disk', 3, other,
                              '--sav-out', outp)
    apf = [l.split() for l in open(out + '/apf.log').read().splitlines()]
    ids = [(l[l.index('id') + 1], int(l[l.index('frame') + 1])) for l in apf if 'id' in l and 'frame' in l]
    first = [f for i, f in ids if i == '11']
    nxt = [f for i, f in ids if i == '12']
    back_in = [f for i, f in ids if i == '11' and nxt and f > max(nxt)]
    check(first, f'drive 1\'s first file is read: frames {first[:3]}')
    check(nxt, f'the next file goes in by itself: frames {nxt[:3]}')
    check(back_in, f'and after it, ejected, the first file again, not File 1 in drive 0: frames {back_in[:3]}')
    check(not [f for i, f in ids if i == '10' and nxt and f > min(nxt)], 'File 1 is not read after the swap began')
    back = open(outp, 'rb').read()
    check(0x5A in back[0x3FF0:0x3FF2], f'the program saw the second disk go in: SRAM ED3FF0 {back[0x3FF0:0x3FF2].hex()}')
    check(j['cmds_failed'] == 0, 'no command came back with an error')

def t_reload():
    print('reload: the game loaded again from the menu with the core kept (APF from Reset Enter, the menu never said closed) starts over')
    out, frames, j, log = run('reload', '--frames', F(150), '--disk', 1, DISK, '--reload', F(60), '--stop-s', 4)
    tr = list(trace(out))
    vec = [i for i in range(len(tr) - 3) if tr[i][:3] == (0, 'R', 0) and tr[i + 1][:3] == (2, 'R', 0x2000)]
    check(len(vec) >= 2, f'the reset vector is read again: at {vec[:3]}')
    n = min(4000, len(tr) - vec[-1])
    same = sum(1 for k in range(n) if tr[vec[0] + k] == tr[vec[-1] + k])
    check(same == n, f'the first {n} accesses after it are as they were at power-on ({same} alike)')
    by = {int(f[0]): f for f in frames}
    check(F(149) in by and int(by[F(149)][6]) > int(by[F(100)][6]), f'the machine runs on to the end: frame {frames[-1][0]}')
    apf = [l.split() for l in open(out + '/apf.log').read().splitlines()]
    again = [int(l[l.index('frame') + 1]) for l in apf if 'id' in l and l[l.index('id') + 1] == '10' and int(l[l.index('frame') + 1]) > F(60)]
    check(again, f'and reads its disk again: frames {again[:3]}')

def t_keys():
    print('keys: the keyboard set up, Start as F1 and Run, L as ESC and X, Y as the chosen pair, R as rapid shot, and Auto on two buttons for a program that never strobes')
    out, frames, j, log = run('keys', '--frames', 290, '--disk', 1, DISK, '--press', '200:start:12', '--press', '222:r:16',
                              '--press', '120:x:6', '--press', '135:y:6', '--press', '150:l:6', '--press', '165:x+l:6',
                              '--keyset', '178:1', '--press', '180:x:6', '--press', '188:y:4',
                              '--keyset', '245:2', '--press', '250:x:6', '--press', '265:y:6',
                              '--io-log', os.path.join(OUT, 'keys', 'io.txt'))
    io = [l.split() for l in open(os.path.join(out, 'io.txt'))]
    pad = {int(l[0]): int(l[2], 16) for l in io if l[1] == 'pad'}
    ready = [n for n in sorted(pad) if pad[n] & 0x200]
    check(ready and ready[0] < 60 and all(pad[n] & 0x200 for n in pad if n >= ready[0]),
          f'pocket_kbd answered the controller\'s setup by frame {ready and ready[0]} and stays set up')
    udr = [(int(l[0]), int(l[3], 16)) for l in io if l[1:3] == ['e8802f', 'R']]
    check((200, 0x63) in udr or any(f in (200, 201) and v == 0x63 for f, v in udr), f'F1 pressed reaches the machine: {udr[:4]}')
    check(any(212 <= f <= 216 and v == 0xE3 for f, v in udr), 'and its release')
    def seen(code, f0, f1):
        return [f for f, v in udr if v == code and f0 <= f <= f1]
    for name, mk, f, n in (('X as SPACE', 0x35, 120, 6), ('Y as RETURN', 0x1D, 135, 6), ('L as ESC', 0x01, 150, 6),
                           ('X as 1, once chosen', 0x02, 180, 6), ('Y as 2', 0x03, 188, 4),
                           ('X as Y, once chosen', 0x16, 250, 6), ('Y as N', 0x2F, 265, 6)):
        check(seen(mk, f, f + 3) and seen(mk | 0x80, f + n, f + n + 4),
              f'{name}: made at {seen(mk, f, f + 3)}, released at {seen(mk | 0x80, f + n, f + n + 4)}')
    check(seen(0x35, 165, 168) and seen(0x01, 165, 170) and seen(0xB5, 171, 177) and seen(0x81, 171, 179),
          f'X and L together: both made and both released ({[(f, hex(v)) for f, v in udr if 165 <= f <= 179]})')
    ok = {0x35, 0x1D, 0x01, 0x02, 0x03, 0x16, 0x2F}
    odd = [(f, hex(v)) for f, v in udr if 110 <= f < 290 and v & 0x7F not in ok | {0x63}]
    check(not odd, f'and nothing else: {odd[:6]}')
    check(all(pad[n] & 0x0C == 0 for n in range(201, 213)) and pad[214] & 0x0C == 0x0C, 'Start is Run on the pad too (left and right)')
    a = ''.join('1' if not pad[n] & 0x10 else '0' for n in range(220, 242))
    check(a == '0001001100110011001000', f'R held from 222: A two frames on, two off ({a}, from frame 220)')
    check(not any(pad[n] & 0x100 for n in pad), 'Auto stays on two buttons: bublbobl never strobes')

def lit(path):
    """The rows and columns of a frame with anything lit, and the frame's colours."""
    sys.path.insert(0, os.path.join(ROOT, 'tools/pocket'))
    sys.dont_write_bytecode = True
    import match_frames
    w, h, rows = match_frames.png(path)
    ys = [y for y, r in enumerate(rows) if any(r)]
    xs = [x // 3 for r in rows for x, v in enumerate(r) if v]
    cols = {tuple(r[x:x + 3]) for r in rows for x in range(0, len(r), 3)}
    return w, h, ys, xs, cols

def t_watchdog():
    print('watchdog: a card command the Pocket drops, leaves taken up, or a 0x0140 never answered: asked again, and the machine starts as it would')
    def start(out):
        tr = list(trace(out))
        v = next(i for i in range(len(tr) - 1) if tr[i][:3] == (0, 'R', 0) and tr[i + 1][:3] == (2, 'R', 0x2000))
        return tr[v:v + 20000]
    ref, *_ = run('wd_ref', '--frames', F(60), '--disk', 1, DISK, '--stop-s', 4)
    want = start(ref)
    for name, args, says in (('wd_ignore', ('--apf-ignore', 2), 'left in the mailbox'),
                             ('wd_hang', ('--apf-hang', 2), 'taken up and never finished'),
                             ('wd_rtr', ('--apf-no-rtr',), '0x0140 left unanswered')):
        out, frames, j, log = run(name, '--frames', F(60), '--disk', 1, DISK, '--stop-s', 4, *args, loaded=False)
        check(says in log, f'{name}: the Pocket did as told ({says})')
        check(j['rom_chunks'] == 256 and j['cmds_failed'] == 0, f'{name}: all 256 chunks of the boot ROM in, none failed ({j["rom_chunks"]}, {j["cmds_failed"]})')
        got = start(out)
        same = sum(1 for a, b in zip(want, got) if a == b)
        check(len(got) == len(want) and same == len(want), f'{name}: the first {len(want)} accesses from the reset vector as without it ({same} alike)')
        check(j['sectors_read'] > 0, f'{name}: and the disk is read ({j["sectors_read"]} sectors)')

def t_boot():
    print('boot: black while the boot ROM loads, the bars with the overlay on, and the message with no ROM')
    out, frames, j, log = run('boot', '--frames', 3, '--save', 2)
    w, h, ys, xs, cols = lit(out + '/f_00002.png')
    check(int(frames[1][7], 16) & 0x10 == 0, 'frame 2 is during the load')
    check(not ys, f'and black: {w} x {h}, {len(ys)} rows lit')
    out, frames, j, log = run('boot_diag', '--frames', 4, '--overlay', '1:1', '--save', 3)
    w, h, ys, xs, cols = lit(out + '/f_00003.png')
    check((0xFF, 0xFF, 0x00) in cols and (0x00, 0xFF, 0xFF) in cols, f'with the overlay on, the bars: {len(cols)} colours')
    out, frames, j, log = run('noboot', '--frames', 30, '--boot', 'none', '--save', 29, loaded=False)
    w, h, ys, xs, cols = lit(out + '/f_00029.png')
    check(int(frames[-1][7], 16) & 0x30 == 0, f'no ROM: not in, a command failed (flags {frames[-1][7]})')
    check(j['cmds_failed'] == 1, f'and the load stopped at the first: {j["cmds_failed"]} failed')
    check(ys and min(ys) >= 112 and max(ys) < 136 and min(xs) >= 56 and max(xs) < 200,
          f'the message in the middle: rows {ys and min(ys)}-{ys and max(ys)}, columns {xs and min(xs)}-{xs and max(xs)}')
    check(cols <= {(0, 0, 0), (0xC0, 0xC0, 0xC0)}, f'grey on black: {sorted(cols)}')

def card_reads(out):
    """APF's reads after the boot ROM, the boot disk's look first, as (id, offset, frame)."""
    rows = []
    for l in (open(out + '/scan.log').read() + open(out + '/apf.log').read()).splitlines():
        p = l.split()
        if 'id' in p and p[p.index('id') + 1] != '1':
            rows.append((int(p[p.index('id') + 1]), int(p[p.index('off') + 1]), int(p[p.index('frame') + 1])))
    return rows

def t_bootdisk():
    print('bootdisk: File 1 without HUMAN.SYS and File 2 with it: File 2 goes in drive 0; chosen in the menu, File 1 is File 1')
    blank = os.path.join(OUT, 'blank.dim')
    hdr = bytearray(open(DISK, 'rb').read(256))
    open(blank, 'wb').write(bytes(hdr) + bytes(154 * 8 * 1024))
    out, frames, j, log = run('bootdisk', '--frames', F(220), '--disk', 1, blank, '--disk', 2, DISK, '--save', F(219))
    rd = card_reads(out)
    scan = [(i, o) for i, o, f in rd[:2]]
    check(scan == [(10, 0x1500), (11, 0x1500)], f'each disk\'s root directory looked at first, past the DIM header: {scan}')
    first = rd[2] if len(rd) > 2 else None
    check(first and first[0] == 11, f'the first sector the machine reads is File 2\'s: {first}')
    check(not black(out + f'/f_{F(219):05d}.png'), 'and it goes on to a picture')
    ref, rframes, *_ = run('bootdisk_ref', '--frames', F(220), '--disk', 1, DISK)
    a = {int(f[0]): f[4] for f in frames}; b = {int(f[0]): f[4] for f in rframes}
    same = [n for n in range(F(100), F(220)) if a.get(n) == b.get(n)]
    check(len(same) > 60, f'the same pictures as bublbobl alone ({len(same)} of {F(220) - F(100)} frames alike)')
    out, frames, j, log = run('bootdisk_menu', '--frames', F(160), '--disk', 1, blank, '--disk', 2, DISK,
                              '--drive0', f'{F(40)}:1', '--drive0', f'{F(80)}:0')
    rd = card_reads(out)
    late = sorted({i for i, o, f in rd if f > F(90)})
    check(10 in late, f'File 1 chosen in the menu is read after it: ids {late}')

def t_nodisk():
    print('nodisk: a game with no disk says so, and the machine is never started')
    out, frames, j, log = run('nodisk', '--frames', 30, '--save', 29, loaded=False)
    w, h, ys, xs, cols = lit(out + '/f_00029.png')
    check(all(int(f[7], 16) & 0x10 == 0 for f in frames), 'the machine never let go (flag 4 off throughout)')
    check(j['cmds_failed'] == 0 and j['rom_chunks'] == 256, f'the boot ROM all in and nothing failed ({j["rom_chunks"]}, {j["cmds_failed"]})')
    check(ys and min(ys) >= 112 and max(ys) < 136 and min(xs) >= 56 and max(xs) < 200,
          f'the message in the middle: rows {ys and min(ys)}-{ys and max(ys)}, columns {xs and min(xs)}-{xs and max(xs)}')
    check(cols <= {(0, 0, 0), (0xC0, 0xC0, 0xC0)}, f'grey on black: {sorted(cols)}')

def t_xdf():
    print('xdf: bublbobl\'s disk as a raw XDF, the DIM\'s header cut off, gives the DIM\'s pictures')
    path = os.path.join(OUT, 'bublbobl.xdf')
    open(path, 'wb').write(open(DISK, 'rb').read()[256:])
    out, frames, j, log = run('xdf', '--frames', F(220), '--disk', 1, path, '--save', F(219))
    ref, rframes, *_ = run('xdf_ref', '--frames', F(220), '--disk', 1, DISK)
    check(os.path.getsize(path) == 1261568, f'the file is 2HD raw: {os.path.getsize(path)} bytes')
    rd = card_reads(out)
    check(rd and rd[0][:2] == (10, 0x1400), f'its root directory looked at with no header: {rd[:1]}')
    a = {int(f[0]): f[4] for f in frames}; b = {int(f[0]): f[4] for f in rframes}
    same = [n for n in range(F(100), F(220)) if a.get(n) == b.get(n)]
    check(not black(out + f'/f_{F(219):05d}.png'), 'a picture')
    check(len(same) > 60, f'the DIM\'s pictures ({len(same)} of {F(220) - F(100)} frames alike)')
    check(j['cmds_failed'] == 0, 'no command came back with an error')

TESTS = {'boot': t_boot, 'watchdog': t_watchdog, 'save': t_save, 'nosave': t_nosave, 'pause': t_pause, 'reset': t_reset, 'mount': t_mount, 'write': t_write, 'swap': t_swap,
         'autoswap': t_autoswap, 'autoswap_on': t_autoswap_on, 'autoswap_eject': t_autoswap_eject, 'autoswap_wrap': t_autoswap_wrap, 'reload': t_reload, 'keys': t_keys,
         'bootdisk': t_bootdisk, 'nodisk': t_nodisk, 'xdf': t_xdf}
if __name__ == '__main__':
    os.makedirs(OUT, exist_ok=True)
    for n in sys.argv[1:] or TESTS:
        TESTS[n]()
    print('all as they should be')
