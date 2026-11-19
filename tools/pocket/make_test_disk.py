#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Three test entries for the card, beside the games, in build/pocket/test/:

  selftest.json, selftest_1.dim   a disk whose boot sector adds one to a byte on its own last sector, read
                                  and written back with IOCS, and one to a byte in SRAM (ED3FF0), then
                                  fills the screen's top half with the first as a letter and the next half
                                  with the second: A and A at its first launch, B and B at the next. So
                                  one look says the disk's write stayed and the save came back.
  memtest.json, memtest_1.dim     a disk whose boot sector writes 4 KB at 64 KB into each megabyte from 0 to 6,
                                  each long its own address, checks them all, waits about ten seconds and checks
                                  them again, then fills the screen with the two results, a letter a megabyte:
                                  G held, X not. GGGGGGG GGGGGGG is RAM that works to the 7 MB SRAM declares; a
                                  memory that folds at 4 MB reads XXXGGGG, as the higher blocks overwrite the lower.
  noboot.json                     a game naming a boot ROM that isn't on the card: what APF or the core
                                  says then.

    python3 -I tools/pocket/make_test_disk.py [build/pocket/test]

tools/pocket/deploy.sh copies them when the folder is there, and takes them off the card when it isn't.
Nothing in them comes from a ROM. The boot sector is hand-assembled 68000, listed below.
"""
import json, os, sys

def dim(body):
    """A 2HD DIM: the header upstream's emulator and build_rom.py's disks have, then 154 tracks of 8 x 1024."""
    hdr = bytearray(256)
    hdr[1:0x9B] = b'\x01' * 154
    hdr[0xAB:0xB8] = b'DIFC HEADER  '
    hdr[0xFE] = 0x16
    return bytes(hdr) + bytes(body)

def assemble(at, parts):
    """Hand-assembled 68000 laid out from `at`: each part is a label, or a function of the labels giving its bytes
    (as hex) and its length, so branches can point forward."""
    labels, pos = {}, at
    for p in parts:
        if isinstance(p, str): labels[p] = pos
        else: pos += p[1]
    out, pos = '', at
    for p in parts:
        if isinstance(p, str): continue
        h = p[0](labels, pos)
        assert len(h) == 2 * p[1], (h, p[1])
        out += h
        pos += p[1]
    return bytes.fromhex(out)

def hx(fmt, n):
    """A fixed piece of code: fmt is hex, with {label} for a 32-bit address."""
    return (lambda L, pc: fmt.format(**{k: '%08x' % v for k, v in L.items()}), n)

def br(op, label, n=2):
    """A short branch (bra.s, bsr.s) or, with n=4, a dbra: the displacement from the opcode's address + 2."""
    if n == 2: return (lambda L, pc: '%s%02x' % (op, (L[label] - pc - 2) & 0xff), 2)
    return (lambda L, pc: '%s%04x' % (op, (L[label] - pc - 2) & 0xffff), 4)

def selftest():
    io = ('323c9070'                                # move.w #$9070,d1       2HD, drive 0
          '243c034c0108'                            # move.l #$034C0108,d2   1024 bytes, C 76 H 1 R 8: the last
          '263c00000400'                            # move.l #$400,d3
          '43f900003000'                            # lea    $3000,a1
          '4e4f')                                   # trap   #15
    code = assemble(0x2000, [
        br('60', 'start'),                          # bra.s start: the IPL wants a branch first
        hx('00' * 30, 30),
        'start',
        hx('7046' + io, 26),                        # moveq #$46,d0          _B_READ the last sector to $3000
        hx('523900003000', 6),                      # addq.b #1,$3000        its first byte, one more
        hx('7045' + io, 26),                        # moveq #$45,d0          _B_WRITE it back
        hx('13fc003100e8e00d', 8),                  # move.b #$31,$E8E00D    SRAM writable
        hx('523900ed3ff0', 6),                      # addq.b #1,$ED3FF0
        hx('13fc000000e8e00d', 8),                  # move.b #$00,$E8E00D    and not
        hx('183900003000', 6),                      # move.b $3000,d4        the disk's count
        br('61', 'fill'),                           # bsr.s  fill            the top half
        hx('183900ed3ff0', 6),                      # move.b $ED3FF0,d4      the SRAM's
        br('61', 'fill'),                           # bsr.s  fill            the bottom half
        'stop',
        br('60', 'stop'),                           # bra.s  stop
        'fill',                                     # twelve lines of 64 letters, A for 1
        hx('06040040', 4),                          # add.b  #$40,d4
        hx('7c0b', 2),                              # moveq  #11,d6
        'line',
        hx('43f9{buf}', 6),                         # lea    buf,a1
        hx('7a3f', 2),                              # moveq  #63,d5
        'char',
        hx('12c4', 2),                              # move.b d4,(a1)+
        br('51cd', 'char', 4),                      # dbra   d5,char
        hx('12fc000d', 4),                          # move.b #13,(a1)+
        hx('12fc000a', 4),                          # move.b #10,(a1)+
        hx('4211', 2),                              # clr.b  (a1)
        hx('43f9{buf}', 6),                         # lea    buf,a1
        hx('7021', 2),                              # moveq  #$21,d0         _B_PRINT
        hx('4e4f', 2),                              # trap   #15
        br('51ce', 'line', 4),                      # dbra   d6,line
        hx('4e75', 2),                              # rts
        'buf',
    ])
    boot = bytearray(1024)
    boot[:len(code)] = code
    assert len(code) + 68 <= 1024
    body = bytearray(154 * 8 * 1024)
    body[:1024] = boot
    return dim(body)

def memtest():
    def block():                                    # a0 = d7 megabytes + 64 KB
        return [hx('2007', 2),                      # move.l d7,d0
                hx('4840', 2),                      # swap   d0              d7 << 16
                hx('e988', 2),                      # lsl.l  #4,d0           d7 << 20
                hx('d0bc00010000', 6),              # add.l  #$10000,d0
                hx('2040', 2),                      # movea.l d0,a0
                hx('3c3c03ff', 4)]                  # move.w #1023,d6        1024 longs
    code = assemble(0x2000, [
        br('60', 'start'),                          # bra.s start: the IPL wants a branch first
        hx('00' * 30, 30),
        'start',
        hx('7e00', 2),                              # moveq  #0,d7           the megabyte
        'wmb', *block(),
        'wl',
        hx('2208', 2),                              # move.l a0,d1
        hx('20c1', 2),                              # move.l d1,(a0)+        each long its own address
        br('51ce', 'wl', 4),                        # dbra   d6,wl
        hx('5247', 2),                              # addq.w #1,d7
        hx('0c470007', 4),                          # cmpi.w #7,d7
        br('6d', 'wmb'),                            # blt.s  wmb
        hx('45f9{res}', 6),                         # lea    res,a2
        br('61', 'check'),                          # bsr.s  check           at once
        hx('203c00550000', 6),                      # move.l #$550000,d0     about ten seconds:
        'wait',
        hx('5380', 2),                              # subq.l #1,d0           18 clocks a turn
        br('66', 'wait'),                           # bne.s  wait
        hx('45f9{res2}', 6),                        # lea    res2,a2
        br('61', 'check'),                          # bsr.s  check           and again
        hx('43f9{buf}', 6),                         # lea    buf,a1          a line: the results four times
        hx('7a03', 2),                              # moveq  #3,d5
        'rep',
        hx('45f9{res}', 6),                         # lea    res,a2
        hx('7c0f', 2),                              # moveq  #15,d6
        'copy',
        hx('12da', 2),                              # move.b (a2)+,(a1)+
        br('51ce', 'copy', 4),                      # dbra   d6,copy
        br('51cd', 'rep', 4),                       # dbra   d5,rep
        hx('12fc000d', 4),                          # move.b #13,(a1)+
        hx('12fc000a', 4),                          # move.b #10,(a1)+
        hx('4211', 2),                              # clr.b  (a1)
        hx('7c0b', 2),                              # moveq  #11,d6          twelve lines
        'line',
        hx('43f9{buf}', 6),                         # lea    buf,a1
        hx('7021', 2),                              # moveq  #$21,d0         _B_PRINT
        hx('4e4f', 2),                              # trap   #15
        br('51ce', 'line', 4),                      # dbra   d6,line
        'stop',
        br('60', 'stop'),                           # bra.s  stop
        'check',                                    # a letter a megabyte at (a2)+: G all held, X not
        hx('7e00', 2),                              # moveq  #0,d7
        'cmb', *block(),
        hx('7447', 2),                              # moveq  #'G',d2
        'cl',
        hx('2208', 2),                              # move.l a0,d1
        hx('b298', 2),                              # cmp.l  (a0)+,d1
        br('67', 'ok'),                             # beq.s  ok
        hx('7458', 2),                              # moveq  #'X',d2
        'ok',
        br('51ce', 'cl', 4),                        # dbra   d6,cl
        hx('14c2', 2),                              # move.b d2,(a2)+
        hx('5247', 2),                              # addq.w #1,d7
        hx('0c470007', 4),                          # cmpi.w #7,d7
        br('6d', 'cmb'),                            # blt.s  cmb
        hx('4e75', 2),                              # rts
        'res',
        hx('20' * 8, 8),                            # the first check's seven letters, a space
        'res2',
        hx('20' * 8, 8),                            # the second's
        'buf',
    ])
    boot = bytearray(1024)
    boot[:len(code)] = code
    assert len(code) + 67 <= 1024
    body = bytearray(154 * 8 * 1024)
    body[:1024] = boot
    return dim(body)

def instance(slots):
    return {"instance": {"magic": "APF_VER_1", "core_select": {"id": 0, "select": False}, "data_path": "",
                         "data_slots": [{"id": i, "filename": f} for i, f in slots], "memory_writes": []}}

def main():
    out = sys.argv[1] if len(sys.argv) > 1 else 'build/pocket/test'
    os.makedirs(out, exist_ok=True)
    open(os.path.join(out, 'selftest_1.dim'), 'wb').write(selftest())
    open(os.path.join(out, 'memtest_1.dim'), 'wb').write(memtest())
    for name, slots in (('selftest', [(1, 'boot.rom'), (10, 'selftest_1.dim')]),
                        ('memtest', [(1, 'boot.rom'), (10, 'memtest_1.dim')]),
                        ('noboot', [(1, 'x68000_noboot.rom'), (10, 'selftest_1.dim')])):
        with open(os.path.join(out, name + '.json'), 'w') as f:
            json.dump(instance(slots), f, indent=4)
            f.write('\n')
    print(f'{out}: selftest.json, selftest_1.dim, memtest.json, memtest_1.dim, noboot.json')

if __name__ == '__main__':
    main()
