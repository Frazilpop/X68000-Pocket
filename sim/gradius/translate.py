#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Copies a tree of the board's VHDL for GHDL, with what Quartus allows and GHDL doesn't written out.
rtl/ itself stays as it is.

    translate.py copy <rtl> <dest>       the VHDL, changed
    translate.py inits <rtl> <dest>      each .mif and the SRAM's .hex as plain hex, for altsyncram.v
    translate.py wrap <ghdl.v> <top.vhd> a module in front of GHDL's top: its ports as the VHDL spells
                                         them, with their defaults, and pMemDat a real inout again
"""
import os, re, sys

def copy(src, dst):
    for root, _, fs in os.walk(src):
        for f in fs:
            if not f.endswith('.vhd'):
                continue
            p = os.path.join(root, f)
            t = open(p, 'rb').read().decode('latin-1')
            # reserved words since VHDL-2008, which port maps with expressions in them need
            t = re.sub(r'\bvmode\b', 'vmode_x', t, flags=re.I)
            t = re.sub(r'\bcontext\b', 'context_x', t, flags=re.I)
            # no space before a keyword
            t = re.sub(r'(\d)downto', r'\1 downto', t)
            if f == 'seekcont.vhd':                 # a case over std_logic with no others
                t = t.replace('when "11" =>', 'when others =>')
            # upstream's D88 path: a formal's range GHDL won't match
            t = re.sub(r'bitlen\s*:\s*in\s+integer range 0 to \w+;', 'bitlen :in integer range 0 to 1023;', t, flags=re.I)
            t = re.sub(r'bitlen\s*=>\s*([\w/]+)\s*,', r'bitlen => (\1)+0,', t, flags=re.I)
            # GHDL leaves an inout between two modules unconnected, so it's split: out, in, enable.
            if f == 'SDRAMC.vhd':
                t = re.sub(r'PMEMDAT\s*:\s*INOUT\s+STD_LOGIC_VECTOR\s*\(\s*15 DOWNTO 0\s*\);',
                           'PMEMDAT : OUT STD_LOGIC_VECTOR(15 DOWNTO 0); PMEMDAT_I : IN STD_LOGIC_VECTOR(15 DOWNTO 0); PMEMDAT_OE : OUT STD_LOGIC;', t, flags=re.I)
                t = t.replace('signal	MDATA        : std_logic_vector(15 downto 0);',
                              'signal	MDATA        : std_logic_vector(15 downto 0);\nsignal	MDATA_OE     : std_logic;')
                t = t.replace("MDATA <=(others=>'Z');", "MDATA_OE <='0';")
                t = t.replace('MDATA<=wrdat;', "MDATA<=wrdat; MDATA_OE<='1';")
                t = t.replace('PMEMDAT   <= MDATA;', 'PMEMDAT   <= MDATA; PMEMDAT_OE <= MDATA_OE;')
                t = t.replace('rddat     <= PMEMDAT when', 'rddat     <= PMEMDAT_I when')
            if f == 'memcont.vhd':
                t = re.sub(r'PMEMDAT(\s*):INOUT(\s*)STD_LOGIC_VECTOR\( 15 DOWNTO 0 \);',
                           'PMEMDAT:OUT STD_LOGIC_VECTOR(15 DOWNTO 0); PMEMDAT_I:IN STD_LOGIC_VECTOR(15 DOWNTO 0); PMEMDAT_OE:OUT STD_LOGIC;', t)
                t = t.replace('PMEMDAT		=>PMEMDAT,', 'PMEMDAT=>PMEMDAT, PMEMDAT_I=>PMEMDAT_I, PMEMDAT_OE=>PMEMDAT_OE,')
            if f == 'X68K_top.vhd':
                t = re.sub(r'pMemDat(\s*): inout std_logic_vector\(15 downto 0\);',
                           'pMemDat : out std_logic_vector(15 downto 0); pMemDat_i : in std_logic_vector(15 downto 0); pMemDat_oe : out std_logic;', t)
                t = re.sub(r'PMEMDAT(\s*):INOUT(\s*)STD_LOGIC_VECTOR\( 15 DOWNTO 0 \);',
                           'PMEMDAT:OUT STD_LOGIC_VECTOR(15 DOWNTO 0); PMEMDAT_I:IN STD_LOGIC_VECTOR(15 DOWNTO 0); PMEMDAT_OE:OUT STD_LOGIC;', t)
                t = t.replace('PMEMDAT		=>pMemDat,', 'PMEMDAT=>pMemDat, PMEMDAT_I=>pMemDat_i, PMEMDAT_OE=>pMemDat_oe,')
            q = os.path.join(dst, os.path.relpath(p, src))
            os.makedirs(os.path.dirname(q), exist_ok=True)
            open(q, 'wb').write(t.encode('latin-1'))

def mif(path):
    text = open(path, errors='replace').read()
    depth = int(re.search(r'DEPTH\s*=\s*(\d+)', text).group(1))
    radix = re.search(r'ADDRESS_RADIX\s*=\s*(\w+)', text).group(1).upper()
    dradix = re.search(r'DATA_RADIX\s*=\s*(\w+)', text).group(1).upper()
    base = {'HEX': 16, 'DEC': 10, 'UNS': 10, 'BIN': 2, 'OCT': 8}
    vals = [0] * depth
    body = text[re.search(r'CONTENT\s+BEGIN', text).end():]
    body = re.sub(r'--[^\n]*', '', body)
    body = re.sub(r'%[^%]*%', '', body)
    for a, v in re.findall(r'(\[[^\]]*\]|[0-9A-Fa-f]+)\s*:\s*([0-9A-Fa-f ]+);', body):
        words = [int(x, base[dradix[:3]]) for x in v.split()]
        if a.startswith('['):
            lo, hi = a[1:-1].split('..')
            lo, hi = int(lo, base[radix[:3]]), int(hi, base[radix[:3]])
            for i in range(lo, hi + 1):
                vals[i] = words[(i - lo) % len(words)]
        else:
            lo = int(a, base[radix[:3]])
            for i, w in enumerate(words):
                vals[lo + i] = w
    return vals

def ihex(path):
    vals = {}
    for line in open(path):
        line = line.strip()
        if not line.startswith(':'):
            continue
        b = bytes.fromhex(line[1:])
        n, a, t = b[0], (b[1] << 8) | b[2], b[3]
        if t == 0:
            # one word a record's address, big-endian in the record
            vals[a] = int.from_bytes(b[4:4 + n], 'big')
    return [vals.get(i, 0) for i in range(max(vals) + 1)]

def inits(src, dst):
    for root, _, fs in os.walk(src):
        for f in fs:
            p = os.path.join(root, f)
            rel = os.path.relpath(p, src)
            if f.endswith('.mif'):
                vals = mif(p)
            elif f == 'sramdefault.hex':
                vals = ihex(p)
            else:
                continue
            q = os.path.join(dst, 'rtl', rel + '.hex')
            os.makedirs(os.path.dirname(q), exist_ok=True)
            with open(q, 'w') as o:
                o.write('\n'.join(f'{v:x}' for v in vals) + '\n')

def stubs(vfile, vhd):
    """Modules with no logic for instances GHDL left unbound on purpose, their ports as the instance
    spells them, directions from the component in the VHDL: upstream's D88 path, which GHDL won't take
    and which the XDF path doesn't use, and the FM chip not chosen."""
    v = open(vfile).read()
    ent = re.sub(r'--[^\n]*', '', open(vhd, 'rb').read().decode('latin-1'))
    out = ['/* verilator lint_off WIDTH */\n/* verilator lint_off PINMISSING */\n']
    for name in ('FDCs', 'diskemu', 'IKAOPM'):
        inst = re.search(r'^\s*' + name + r'\s*(?:#\((.*?)\)\s*)?\w+\s*\((.*?)\);', v, re.S | re.M)
        m = re.search(r'component\s+' + name + r'\b(.*?)end\s+component', ent, re.S | re.I)
        if not inst or not m:
            continue
        body = m.group(1)
        dirs = {}
        for names, d, rest in re.findall(r'([\w\s,]+?)\s*:\s*(in|out|inout|buffer)\s+([^;]+)',
                                         body[re.search(r'port\s*\(', body, re.I).end():], re.I):
            for n in names.split(','):
                dirs[n.strip().lower()] = ({'in': 'input', 'out': 'output', 'inout': 'inout', 'buffer': 'output'}[d.lower()],
                                           'downto' in rest.lower())
        params = re.findall(r'\.(\w+)\(', inst.group(1) or '')
        lines = []
        for p in re.findall(r'\.(\w+)\s*\(', inst.group(2)):
            d, vec = dirs.get(p.lower(), ('input', False))
            lines.append(f'  {d} wire {"[127:0] " if vec else ""}{p}')
        head = f'module {name}' + (' #(' + ', '.join(f'parameter {p} = 0' for p in params) + ')' if params else '')
        out.append(head + ' (\n' + ',\n'.join(lines) + '\n);\nendmodule\n')
    sys.stdout.write(''.join(out))

def wrap(vfile, vhd):
    v = open(vfile).read()
    # names the VHDL may use and SystemVerilog keeps for itself
    v = re.sub(r'\b(int|bit|byte|do|final|ref|type|this|logic|string|shortint|longint|unique|priority|bind|class|const|context|cover|expect|export|extern|import|inside|interface|new|packed|program|property|rand|randc|return|sequence|solve|static|struct|super|tagged|union|var|virtual|void|with|within|alias|before|break|chandle|continue|dist|endclass|enum|foreach|forkjoin|global|local|matches|modport|package|pure|timeprecision|timeunit)\b(?!["\'])', r'\1_x', v)
    # the copy's rename, undone on the one Verilog module with such a port
    v = re.sub(r'x68k_native_crtc\b.*?\);', lambda m: re.sub(r'\.vmode_x\(', '.VMODE(', m.group(0), flags=re.I), v, flags=re.S)
    m = re.search(r'^module X68K_top\s*\((.*?)\);', v, re.S | re.M)
    ports = re.findall(r'(input|output|inout)\s*(\[[^\]]*\])?\s*(\w+)', m.group(1))
    ent = open(vhd, 'rb').read().decode('latin-1')
    ent = ent[re.search(r'entity X68K_top', ent, re.I).start():re.search(r'end X68K_top', ent, re.I).start()]
    ent = re.sub(r'--[^\n]*', '', ent)
    defaults = {}
    for n, val in re.findall(r"(\w+)\s*:\s*in\s+std_logic(?:_vector\s*\([^)]*\))?\s*:=\s*('[01]'|\"[01]+\")", ent, re.I):
        defaults[n.lower()] = ("'1" if '1' in val else "'0") if val[0] == "'" else f"{len(val) - 2}'b{val[1:-1]}"
    lines, conns = [], []
    for d, w, n in ports:
        if n in ('pMemDat_i', 'pMemDat_oe'):
            continue
        if n == 'pMemDat':
            lines.append('\tinout wire [15:0] pMemDat')
            continue
        dflt = defaults.get(n.lower()) if d == 'input' else None
        lines.append(f'\t{d} logic {w + " " if w else ""}{n}{" = " + dflt if dflt else ""}')
    for d, w, n in ports:
        if n == 'pMemDat':
            conns.append('.pMemDat(sd_o)')
        elif n == 'pMemDat_i':
            conns.append('.pMemDat_i(pMemDat)')
        elif n == 'pMemDat_oe':
            conns.append('.pMemDat_oe(sd_oe)')
        else:
            conns.append(f'.{n}({n})')
    out = ['// X68K_top as the VHDL spells it, in front of GHDL\'s translation (sim/gradius/translate.py)',
           'module X68K_top (', ',\n'.join(lines), ');',
           '\twire [15:0] sd_o; wire sd_oe;',
           "\tassign pMemDat = sd_oe ? sd_o : 16'hzzzz;",
           '\tX68K_top_ghdl chip (' + ', '.join(conns) + ');', 'endmodule', '']
    sys.stdout.write('\n'.join(out) + v[:m.start()] + re.sub(r'^module X68K_top', 'module X68K_top_ghdl', m.group(0)) + v[m.end():])

if __name__ == '__main__':
    {'copy': copy, 'inits': inits, 'wrap': wrap, 'stubs': stubs}[sys.argv[1]](*sys.argv[2:])
