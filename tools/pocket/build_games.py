"""More games for the card, beyond the ten sets: the pad-playable titles of MAME's
x68k_flop list, found by CRC in a folder of zips (zips inside zips are opened too).

    python3 -I tools/pocket/build_games.py <folder with the zips> build/pocket/games [--list]

Writes Assets/x68000/frazilpop.X68000/Games/<title>.json and Assets/x68000/common/games/
<set>_<n>.dim (with the boot ROM beside them, as data_path points there) under the output
folder. A game is made only when every disk of the set is found, there are at most seven
(the core's slots) and each is a 2HD-family image the disk emulator reads. XDFs go under the
standard DIM header. The list below is the arcade, action, sports and puzzle titles: the core
has the pad and F1/F2 only, so games driven from the keyboard or mouse are left out.
"""
import io, json, os, re, sys, zipfile, zlib, xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
MAME_XML = os.path.join(HERE, '..', '..', 'third_party', 'mame', 'hash', 'x68k_flop.xml')
BOOT = os.path.join(HERE, '..', '..', 'build', 'pocket', 'x68000_boot.rom')
TEN = {'bublbobl', 'salamand', 'gradius', 'chorensa', 'akumajo', 'ffight', 'parodius', 'nemesis', 'sf2ce', 'ssf2'}

PICKS = """
aburner2 ajax aliensyn arknoid2 asuka120 atomrobo blodia bombermn bnzabros bosco cameltry chasehq choujin
columns cybrcore cybrbloc daimakai deflektr deltaarm dtwinbeec dinoland downtown dspirit dynduke exterlin
fantzone fshark galaga88 garou garou2 gemini genocide genocid2c genpei geoseal heavynov imagefig klax ktiger
loopz madstlkr mahoudai marble motos nekdodge neksoccr overtake pacman pacmania pbpinbal phalanx pipedrem
pleague ppersia prosoccr ptennwc proyak puyopuyo puzznic quarth rtype relics rtishtar sharrier shangon
solfeace spindiz2 starlust starwars strider syvalion tblade tetris tf2 flstory tnzs twinbee usvball viewpoin
xenon2 xevious quenduel terracre mrdo paclandc digdug baraduke chelnov starfrce libbler cclimber butasan
dbuster excthour argos ys ys3 algarna dashyar
darius dariusdt dariuse galaxian galaxia2 galax68k galagad grobda asteroid sinv frogger froggero mappy1
mappy2 tinyhopp pacmand pacmanit timeplt toypop rallyx druaga heiankyo hnkyo68k ldrun1 ldrun mario smb
excitbik balonfgt batlcity citycon doordoor wrecking xevioud libblerd laydock psycharr nemes93 nemes94
cubegrd3 stphalnx xtype sss sss2 starfght putiplin fmission fmissio2 superfm bf92 amheroesa gaiafght
gigafght duelfght karatedo sdfightr blanka lilchin lilchind lilchinf formulax formxt formxy fastlap
pole2win powerrac clearlap terradrv tetrisse tetrislc tetriscf nishitet columnsg columnsm tinyclmn yacolumn
hextris pentaris flipull gemdrop spannera spannerx lockon lockon2 lockon3 rayersht xfireex tokkoukf flmwing
souhoubp zeromast windblst starpuls vulquar metlunit metluni2 fassbust actshoot accheat guardian guardans
integral gaiarm bluwaver ilmlaser millisht fantsht flyshoot orashoot wtank tank6 tankbatl tankbatt hvrcraft
deepscan deepscak kingou2 sbbknuck bbknuckl dynamics atennis popjack macross starlusd angeldiv fzsenki
""".split()

DIM_HEADER = bytes([0]) + b'\x01' * 154 + b'\x00' * 16 + b'DIFC HEADER  ' + b'\x00' * 70 + b'\x16\x00'
XDF_SIZES = {1261568}
DIM_TYPES = {0, 1, 2, 3, 9, 0x11}

def title(desc):
    t = desc
    for a, b in (('·', '-'), ('・', ' '), ('²', '2'), ('ä', 'a'), ('ü', 'u'), ('é', 'e'), ('É', 'E'),
                 (': ', ' - '), (':', ' -'), ('/', '-'), ('?', ''), ('"', ''), ('*', ''), ('|', '-'), ('\\', '-')):
        t = t.replace(a, b)
    t = re.sub(r'\s+', ' ', t.encode('ascii', 'ignore').decode()).strip(' .')
    return t[:80]

def scan(folder):
    """CRC -> bytes of every disk image in every zip (nested zips too), and XDF->DIM CRCs."""
    found = {}
    def walk(zf, depth):
        for info in zf.infolist():
            n = info.filename.lower()
            if n.endswith('.zip') and depth < 3:
                try:
                    walk(zipfile.ZipFile(io.BytesIO(zf.read(info))), depth + 1)
                except zipfile.BadZipFile:
                    pass
            elif info.file_size % 512 == 256 or info.file_size in XDF_SIZES:
                found.setdefault(info.CRC, (zf, info))
    zips = sorted(f for f in os.listdir(folder) if f.lower().endswith('.zip'))
    for k, f in enumerate(zips):
        print(f"scan {k + 1} of {len(zips)}: {f}", flush=True)
        try:
            walk(zipfile.ZipFile(os.path.join(folder, f)), 0)
        except zipfile.BadZipFile:
            pass
    return found

def main():
    folder, out = sys.argv[1], sys.argv[2]
    root = ET.parse(MAME_XML).getroot()
    sets = {}
    for sw in root.findall('software'):
        roms = [(int(r.get('crc'), 16), int(r.get('size'))) for p in sw.findall('part')
                if p.get('interface') == 'floppy_5_25' for r in p.iter('rom') if r.get('crc')]
        sets[sw.get('name')] = (sw.findtext('description'), sw.findtext('year'), roms)
    found = scan(folder)
    xdf = {}  # MAME CRC of a DIM that an XDF on hand reaches under the header
    jdir = os.path.join(out, 'Assets', 'x68000', 'frazilpop.X68000', 'Games')
    ddir = os.path.join(out, 'Assets', 'x68000', 'common', 'games')
    os.makedirs(jdir, exist_ok=True); os.makedirs(ddir, exist_ok=True)
    made, missing = [], []
    picks = [p for p in dict.fromkeys(PICKS) if p not in TEN]
    for i, name in enumerate(picks):
        print(f"{i + 1} of {len(picks)}: {name}", flush=True)
        if name not in sets:
            missing.append((name, 'not in MAME\'s list')); continue
        desc, year, roms = sets[name]
        if not 1 <= len(roms) <= 7:
            missing.append((name, f'{len(roms)} disks')); continue
        datas = []
        for crc, size in roms:
            if crc in found:
                zf, info = found[crc]; d = zf.read(info)
            else:
                d = None
                if not xdf:
                    for c, (zf, info) in found.items():
                        if info.file_size in XDF_SIZES:
                            xdf[zlib.crc32(DIM_HEADER + zf.read(info))] = (zf, info)
                if crc in xdf:
                    zf, info = xdf[crc]; d = DIM_HEADER + zf.read(info)
            if d is None or zlib.crc32(d) != crc or len(d) % 512 != 256 or d[0] not in DIM_TYPES or len(d) > 0x200000:
                datas = None; break
            datas.append(d)
        if not datas:
            missing.append((name, 'a disk not on hand')); continue
        slots = [{"id": 1, "filename": "x68000_boot.rom"}]
        for n, d in enumerate(datas):
            fn = f"{name}_{n + 1}.dim"
            path = os.path.join(ddir, fn)
            if not os.path.exists(path):
                with open(path, 'wb') as fh:
                    fh.write(d)
            slots.append({"id": 10 + n, "filename": fn})
        inst = {"instance": {"magic": "APF_VER_1", "core_select": {"id": 0, "select": False},
                             "data_path": "games/", "data_slots": slots, "memory_writes": []}}
        t = title(desc)
        with open(os.path.join(jdir, t + '.json'), 'w') as fh:
            json.dump(inst, fh, indent=4); fh.write('\n')
        made.append((name, t, len(datas)))
    if os.path.exists(BOOT):
        with open(BOOT, 'rb') as a, open(os.path.join(ddir, 'x68000_boot.rom'), 'wb') as b:
            b.write(a.read())
    else:
        print('NO BOOT ROM: run build_rom.py first'); sys.exit(1)
    print(f"\n{len(made)} games made, {len(missing)} left out")
    for m in missing:
        print('  left out:', *m)
    with open(os.path.join(out, 'games.txt'), 'w') as fh:
        for name, t, n in sorted(made, key=lambda m: m[1].lower()):
            fh.write(f"{name}\t{n}\t{t}\n")

if __name__ == '__main__':
    main()
