# SPDX-License-Identifier: GPL-3.0-or-later
"""What the Games folder's sets answer to, in MAME: each set run with a plan, every picture hashed, and
the runs compared with the one where nothing is pressed.

    python3 -I tools/pocket/games_census.py run <jobs> [--frames N] [--parallel N]
    python3 -I tools/pocket/games_census.py diff <set ...|all> [--runs base,start,...]
    python3 -I tools/pocket/games_census.py sheet <pairs> <out.png> [--lag N]

<jobs> is a file of "set plan" lines; the plan is tools/pocket/plans/census/<plan>.plan (mame_x68k_census.lua's
format) and "base" is the run with nothing pressed, which every comparison needs. Each run goes to
build/games_census/<set>/<plan>/ (MAME's picture every 100 frames) and <plan>.json (their hashes), and is
skipped if that is there already. The disks come from the Games folder that build_games.py writes
(build/pocket/games/Games/<title>/<set>_<n>.dim, or <title>/ for the core's own ten), the swap as the core does it (AUTO_SWAP=60,
AUTO_SWAP_ON=277), the pad as the core's Auto.

diff prints, for each set, the first frame at which each run's picture leaves the base run's ("." for
never): a set that a key moves and the pad doesn't is one that waits for that key. A move is not always a
start (ESC pauses some games), so sheet puts the two pictures side by side, a while after the move, for
lines "set plan [frame]", to be looked at.
"""
import hashlib, json, os, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
OUT = os.path.join(ROOT, 'build', 'games_census')
PLANS = os.path.join(ROOT, 'tools', 'pocket', 'plans', 'census')
GAMES = os.path.join(ROOT, 'build', 'pocket', 'games')

def set_dir(s):
    """The folder holding the set's disks: one of the core's own sets at the top, the rest in Games/."""
    for base in (os.path.join(GAMES, 'Games'), GAMES):
        for t in os.listdir(base):
            if os.path.exists(os.path.join(base, t, s + '_1.dim')):
                return os.path.join(base, t)
    sys.exit(f'{s}: no {s}_1.dim in {GAMES}')
FONT = '/System/Library/Fonts/Helvetica.ttc'

def opt(args, name, default):
    if name in args:
        i = args.index(name); v = args[i + 1]; del args[i:i + 2]; return v
    return default

def hashes(s, plan):
    p = os.path.join(OUT, s, plan + '.json')
    return {int(k): h for k, h in json.load(open(p)).items()} if os.path.exists(p) else None

def leaves(a, b):
    for f in sorted(a):
        if f in b and a[f] != b[f]:
            return f
    return None

def run(args):
    frames = opt(args, '--frames', '6000'); par = int(opt(args, '--parallel', '2'))
    jobs = [l.split() for l in open(args[0]) if l.strip() and not l.startswith('#')]
    def one(job):
        s, plan = job
        out = os.path.join(OUT, s, plan)
        if os.path.exists(out + '.json'):
            return
        os.makedirs(out, exist_ok=True)
        cmd = ['sh', 'tools/pocket/mame_oracle.sh', 'tools/mame_x68k_census.lua', s, 'SET_DIR=' + set_dir(s),
               'CENSUS_OUT=' + out + '.log', 'CENSUS_FRAMES=' + frames, 'SNAP_DIR=' + out, 'SNAP_STEP=100',
               'SRAM_SEED=1', 'PAD_KIND=auto', 'AUTO_SWAP=60', 'AUTO_SWAP_ON=277']
        if plan != 'base':
            cmd.append('PLAN=' + os.path.join(PLANS, plan + '.plan'))
        subprocess.run(cmd, cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        h = {int(f[1:7]): hashlib.md5(open(os.path.join(out, f), 'rb').read()).hexdigest()
             for f in sorted(os.listdir(out)) if f.endswith('.png')}
        json.dump(h, open(out + '.json', 'w'))
    n = 0
    with ThreadPoolExecutor(par) as ex:
        for _ in ex.map(one, jobs):
            n += 1
            print(f'{n} of {len(jobs)}', flush=True)

def diff(args):
    runs = opt(args, '--runs', None)
    sets = sorted(os.listdir(OUT)) if args == ['all'] else args
    for s in sets:
        b = hashes(s, 'base')
        if not b:
            continue
        names = runs.split(',') if runs else sorted(f[:-5] for f in os.listdir(os.path.join(OUT, s))
                                                     if f.endswith('.json') and f != 'base.json')
        cells = []
        for r in names:
            h = hashes(s, r)
            cells.append(f'{r} {"-" if h is None else (leaves(b, h) or ".")}')
        print(f'{s:10s} ' + '  '.join(f'{c:16s}' for c in cells))

def sheet(args):
    lag = int(opt(args, '--lag', '200'))
    tiles = []
    for l in open(args[0]):
        p = l.split()
        if not p:
            continue
        s, r = p[0], p[1]
        d = int(p[2]) if len(p) > 2 else leaves(hashes(s, 'base'), hashes(s, r))
        f = min(max(hashes(s, 'base')), (d or 6000) + lag)
        for which in ('base', r):
            tiles += ['-label', f'{s} {which} {f}', os.path.join(OUT, s, which, 'm%06d.png' % f)]
    subprocess.run(['montage'] + tiles + ['-tile', '6x', '-geometry', '+4+4', '-font', FONT, '-pointsize', '11',
                    args[1]], check=True)

if __name__ == '__main__':
    what, rest = sys.argv[1], sys.argv[2:]
    {'run': run, 'diff': diff, 'sheet': sheet}[what](rest)
