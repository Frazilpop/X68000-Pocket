# SPDX-License-Identifier: GPL-3.0-or-later
"""The X68000 core's game list, made on a computer with the Pocket's SD card in it.

    python3 <card>/Cores/frazilpop.X68000/make_instances.py [<card>]
    python3 make_instances.py --messages

Each folder of disk images in Assets/x68000/common/ becomes an instance JSON in
Assets/x68000/frazilpop.X68000/, named after the folder, which the Pocket lists as a
game. It reads the rules from the core's instance-packager.json beside it and writes
what Pupdate's and Pocket Sync's packager write, byte for byte, but leaves out a
folder with no disk image in it rather than writing an entry that cannot start.
Nothing on the card is deleted. With no card given, the card is the one this script
sits on. Python 3, nothing to install.

Every message it can show is in MESSAGES below; --messages lists them all, grouped by
when they appear, with an example of each.
"""
import fnmatch, json, os, sys

CORE = 'frazilpop.X68000'

# id: (text, when it appears, example values)
MESSAGES = {
    'usage': ("Usage: python3 make_instances.py [the SD card's folder]",
              "more than one folder is given, or an option it doesn't know", {}),
    'no_card': ("{path} isn't a Pocket SD card with the X68000 core on it (there's no "
                "Cores/frazilpop.X68000/instance-packager.json). Give the card's folder, "
                "for example: python3 make_instances.py /Volumes/POCKET",
                "the folder given, or the one the script sits in, has no X68000 core",
                {'path': '/Users/me/Downloads'}),
    'no_common': ("There's no Assets/x68000/common folder on the card. Make it, put boot.rom "
                  "and a folder for each game in it, then run this again.",
                  "the card has the core but no Assets/x68000/common", {}),
    'no_boot': ("Warning: there's no boot.rom in Assets/x68000/common – the Pocket won't "
                "start a game without it.",
                "common/ has no boot.rom (the games are still written)", {}),
    'boot_size': ("Warning: boot.rom is {size} bytes, and the core needs one of exactly "
                  "1,048,576 – make it again as the README says.",
                  "boot.rom is there but the wrong size (the games are still written)",
                  {'size': '524,288'}),
    'wrote': ("Wrote {name} – {disks}",
              "a game's entry is new or its disks have changed", {'name': 'Bubble Bobble', 'disks': '2 disks'}),
    'disk_one': ("1 disk", "inside 'wrote', for a game with one disk", {}),
    'disk_many': ("{n} disks", "inside 'wrote', for a game with more than one", {'n': '3'}),
    'too_many': ("Skipped {name}: it has {n} disk images, and the core takes {limit} at most.",
                 "a game folder holds more disk images than the core takes",
                 {'name': 'Games/Ys III', 'n': '8', 'limit': '7'}),
    'no_disks': ("Skipped {name}: there's no .dim, .xdf or .hdm disk image in it.",
                 "a folder holds files but none of them a disk image",
                 {'name': 'Bubble Bobble (manual)'}),
    'write_failed': ("Couldn't write {path}: {error}",
                     "the card refuses a write (full, read-only, ejected)",
                     {'path': 'Assets/x68000/frazilpop.X68000/Bubble Bobble.json',
                      'error': 'No space left on device'}),
    'none': ("There are no game folders in Assets/x68000/common. Give each game a folder of "
             "its own there with its disk images in it, then run this again.",
             "no folder in common/ holds a disk image", {}),
    'done': ("{made} written, {same} already up to date{skipped}. The games are listed under "
             "Computer → X68000 on the Pocket.",
             "at the end, when at least one game has an entry",
             {'made': '12', 'same': '3', 'skipped': ', 1 skipped'}),
    'done_skipped': (", {n} skipped", "inside 'done', when any folder was skipped", {'n': '1'}),
}


def text(mid, **values):
    return MESSAGES[mid][0].format(**values)


def say(mid, **values):
    print(text(mid, **values))


def review():
    """Every message, grouped by when it appears, with its example filled in."""
    for mid, (t, when, example) in MESSAGES.items():
        print(f'{mid} – {when}\n    {t.format(**example)}\n')


def card_root(args):
    if args:
        return os.path.abspath(args[0])
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.dirname(os.path.dirname(here))


def disks_in(folder, names, rules):
    """The folder's disk images in the packager's order, rule by rule, each rule's ascending,
    numbered from the first rule's slot on: Disk 1, Disk 2 … (The packager counts each rule
    from its own id, so a folder mixing .dim and .DIM gets two Disk 1s from it.)"""
    files = [n for n in names if not n.startswith('.') and os.path.isfile(os.path.join(folder, n))]
    order = []
    for rule in rules:
        order += [n for n in sorted(f for f in files if fnmatch.fnmatchcase(f, rule['filename'])) if n not in order]
    first = rules[0]['id']
    return [{'id': first + k, 'filename': n} for k, n in enumerate(order)], files


def main():
    try:
        sys.stdout.reconfigure(errors='replace')
    except AttributeError:
        pass
    args = sys.argv[1:]
    if args == ['--messages']:
        review()
        return 0
    if len(args) > 1 or any(a.startswith('-') for a in args):
        say('usage')
        return 2
    root = card_root(args)
    spec_path = os.path.join(root, 'Cores', CORE, 'instance-packager.json')
    if not os.path.isfile(spec_path):
        say('no_card', path=root)
        return 1
    with open(spec_path, encoding='utf-8') as f:
        spec = json.load(f)
    platform = spec['platform_id']
    common = os.path.join(root, 'Assets', platform, 'common')
    out = os.path.join(root, *spec['output'].split('/'))
    limit = spec['slot_limit']['count']
    rules = spec['data_slots']
    not_games = set(spec.get('overrides', {}))
    if not os.path.isdir(common):
        say('no_common')
        return 1

    boot = os.path.join(common, 'boot.rom')
    if not os.path.isfile(boot):
        say('no_boot')
    elif os.path.getsize(boot) != 0x100000:
        say('boot_size', size=f'{os.path.getsize(boot):,}')

    made = same = skipped = 0
    for folder, dirs, names in os.walk(common):
        dirs[:] = sorted(d for d in dirs if not d.startswith('.'))
        rel = os.path.relpath(folder, common).replace(os.sep, '/')
        if rel == '.' or rel in not_games:
            continue
        disks, files = disks_in(folder, names, rules)
        if not disks:
            if files:
                say('no_disks', name=rel)
                skipped += 1
            continue
        if len(disks) > limit:
            say('too_many', name=rel, n=len(disks), limit=limit)
            skipped += 1
            continue
        entry = {'instance': {'magic': 'APF_VER_1', 'data_path': rel + '/',
                              'data_slots': disks,
                              'memory_writes': []}}
        body = json.dumps(entry, indent=2, ensure_ascii=False).encode('utf-8')
        path = os.path.join(out, *rel.split('/')) + '.json'
        try:
            with open(path, 'rb') as f:
                if f.read() == body:
                    same += 1
                    continue
        except OSError:
            pass
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, 'wb') as f:
                f.write(body)
        except OSError as e:
            say('write_failed', path=os.path.relpath(path, root).replace(os.sep, '/'), error=e.strerror or e)
            return 1
        disks_text = text('disk_one') if len(disks) == 1 else text('disk_many', n=len(disks))
        say('wrote', name=rel, disks=disks_text)
        made += 1

    if made + same == 0:
        say('none')
        return 1
    say('done', made=made, same=same, skipped=text('done_skipped', n=skipped) if skipped else '')
    return 0


if __name__ == '__main__':
    sys.exit(main())
