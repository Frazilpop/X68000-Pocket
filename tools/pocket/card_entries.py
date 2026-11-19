"""The card's X68000 list entries checked and put in name order (run by tools/pocket/deploy.sh).

    python3 -I tools/pocket/card_entries.py <card>/Assets/x68000 frazilpop.X68000 build/pocket/card_order.txt

1. A game folder (in common/ or common/Games/) holding no file at all is taken off: the packager would
   make an entry for it with no disk.
2. Every instance JSON under Assets/x68000/<core>/ is read: one that doesn't parse, names a folder or a
   file not on the card, or has no disk slot (ids 10-16) is reported and taken off.
3. Each folder of entries is written again in name order (case folded), so the card's directory order
   is the list's: the order the card had first, the position of every entry, is written to the record.
"""
import json, os, sys

assets, core, record = sys.argv[1:4]
common = os.path.join(assets, 'common')
inst = os.path.join(assets, core)

def entries(d):
    return [n for n in os.listdir(d) if not n.startswith('._')]

for base in (common, os.path.join(common, 'Games')):
    if not os.path.isdir(base):
        continue
    for t in entries(base):
        p = os.path.join(base, t)
        if os.path.isdir(p) and t != 'Games' and not entries(p):
            for n in os.listdir(p):
                os.remove(os.path.join(p, n))
            os.rmdir(p)
            print(f'  empty game folder {os.path.relpath(p, common)} taken off')

good = bad = 0
for root, ds, fs in os.walk(inst):
    for f in fs:
        if not f.endswith('.json') or f.startswith('._'):
            continue
        p = os.path.join(root, f)
        why = None
        try:
            i = json.load(open(p))['instance']
            dp = os.path.join(common, i.get('data_path', ''))
            disks = [s for s in i['data_slots'] if 10 <= int(s['id']) <= 16]
            if not disks:
                why = 'no disk'
            else:
                gone = [s['filename'] for s in i['data_slots']
                        if not os.path.isfile(os.path.join(dp, s['filename']))
                        and not os.path.isfile(os.path.join(common, s['filename']))]
                if gone:
                    why = 'not on the card: ' + ', '.join(gone)
        except (ValueError, KeyError, TypeError) as e:
            why = f'unreadable ({e})'
        if why:
            os.remove(p)
            dot = os.path.join(root, '._' + f)
            if os.path.exists(dot):
                os.remove(dot)
            print(f'  entry {os.path.relpath(p, inst)} taken off: {why}')
            bad += 1
        else:
            good += 1

lines = []
for root, ds, fs in list(os.walk(inst, topdown=False)):
    names = entries(root)
    lines += [f'{os.path.relpath(root, inst)}\t{k + 1}\t{n}' for k, n in enumerate(names)]
    want = sorted(names, key=lambda n: (n.casefold(), n))
    if names == want:
        continue
    tmp = root.rstrip('/') + '.sorting'
    os.mkdir(tmp)
    for n in want:
        os.rename(os.path.join(root, n), os.path.join(tmp, n))
    for n in os.listdir(root):          # what's left is ._ files, rewritten by macOS if needed
        os.remove(os.path.join(root, n))
    os.rmdir(root)
    os.rename(tmp, root)
    print(f'  {os.path.relpath(root, assets)}: {len(names)} entries written in name order')
with open(record, 'w') as fh:
    fh.write('\n'.join(lines) + '\n')
print(f'  {good} list entries checked, each with its disks on the card; {bad} taken off')
