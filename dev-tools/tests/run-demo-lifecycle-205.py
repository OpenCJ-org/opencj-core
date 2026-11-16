"""Run demo lifecycle regression fixtures on isolated servers; no database or live players."""

from pathlib import Path
import argparse
import hashlib
import json
import re
import shutil
import subprocess
import time
import uuid

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('maps', nargs='*', default=['mp_killhouse'])
parser.add_argument('--binary', default='/workspace/cod4x-server/bin/cod4x18_dedrun')
parser.add_argument(
    '--baseline', action='store_true', help='Test committed scripts in the isolated fixture'
)
options = parser.parse_args()
for mapname in options.maps or ['mp_killhouse']:
    tag = 'demo-lifecycle-205-' + uuid.uuid4().hex[:8]
    home = root / 'dev-tools/local' / tag
    mod = home / 'mods/opencj'
    mod.mkdir(parents=True)
    for name in ['opencj', 'maps']:
        shutil.copytree(root / 'server-gsc' / name, mod / name)
    if options.baseline:
        for name in ['opencj', 'maps']:
            for p in (mod / name).rglob('*.gsc'):
                p.unlink()
        paths = subprocess.check_output(
            ['git', 'ls-files', 'opencj', 'maps'], cwd=root / 'server-gsc', text=True
        ).splitlines()
        for name in paths:
            target = mod / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(
                subprocess.check_output(
                    ['git', 'show', 'HEAD:server-gsc/' + name], cwd=root / 'server-gsc'
                )
            )
    sourceHashes = {
        str(p.relative_to(mod)): hashlib.sha256(p.read_bytes()).hexdigest()
        for folder in ['opencj', 'maps']
        for p in (mod / folder).rglob('*.gsc')
    }
    for name in ['mod.ff', 'z_opencj.iwd']:
        (mod / name).symlink_to('/mod-assets/' + name)
    (home / 'usermaps').symlink_to('/game/usermaps')
    (home / 'plugins').mkdir()

    (home / 'steamclient.so').symlink_to('/game/steamclient.so')
    shutil.copyfile(
        root / 'dev-tools/tests/demo-lifecycle-205.gsc', mod / 'opencj/platformtest.gsc'
    )
    init = mod / 'opencj/events/init.gsc'
    s = init.read_text()
    init.write_text(
        s.replace('    level.playerCount = 0;', '    return;\n    level.playerCount = 0;', 1)
    )
    game = mod / 'maps/mp/gametypes/cj.gsc'
    s = game.read_text()
    game.write_text(
        s.replace(
            'main()\n{', 'main()\n{\n    thread openCJ' + chr(92) + 'platformTest::main();', 1
        )
    )
    # Test clients must not reach account/database callbacks in this isolated fixture.
    callback = mod / 'maps/mp/gametypes/_callbacksetup.gsc'
    source = re.sub(r'//[^\n]*', '', callback.read_text())
    matches = list(re.finditer(r'(CodeCallback_\w+)\([^)]*\)\s*\{', source))
    for match in reversed(matches):
        if match.group(1) == 'CodeCallback_FragButton':
            continue
        start = match.end()
        end = start
        depth = 1
        while depth:
            if source[end] == '{':
                depth += 1
            elif source[end] == '}':
                depth -= 1
            end += 1
        source = source[:start] + '\n' + source[end - 1 :]
    callback.write_text(source)
    name = 'opencj-' + tag
    args = [
        'docker',
        'compose',
        'run',
        '-d',
        '--no-deps',
        '--name',
        name,
        "--workdir",
        "/workspace/" + str(home.relative_to(root)),
        'server',
        options.binary,
    ]
    for k, v in [
        ('fs_basepath', '/game'),
        ('fs_homepath', '/workspace/dev-tools/local/' + tag),
        ('fs_game', 'mods/opencj'),
        ('dedicated', '2'),
        ('net_port', '28964'),
        ('sv_maxclients', '2'),
        ('sv_authorizemode', '0'),
        ('com_hunkMegs', '1024'),
        ('developer', '1'),
        ('g_gametype', 'cj'),
        ('opencj_isolated_demo_test', '1'),
    ]:
        args += ['+set', k, v]
    args += ['+map', mapname]
    try:
        subprocess.run(args, cwd=root / 'dev-tools', check=True, capture_output=True)
        for _ in range(45):
            time.sleep(1)
            log = subprocess.check_output(
                ['docker', 'logs', name], stderr=subprocess.STDOUT, text=True
            )
            if (
                'DEMO LIFECYCLE COMPLETE' in log
                or 'script compile error' in log
                or 'script runtime error' in log
            ):
                break
        if 'script compile error' in log or 'script runtime error' in log:
            pos = (
                log.index('script compile error')
                if 'script compile error' in log
                else log.index('script runtime error')
            )
            print(log[pos : pos + 1400], flush=True)
        (home / 'console.log').write_text(log)
        (home / 'result.json').write_text(
            json.dumps(
                {
                    'baseline': options.baseline,
                    'sourceHashes': sourceHashes,
                    'passed': 'DEMO LIFECYCLE COMPLETE failures=0' in log
                    and 'script compile error' not in log
                    and 'script runtime error' not in log,
                    'summary': [l for l in log.splitlines() if 'DEMO LIFECYCLE' in l],
                },
                indent=2,
            )
            + '\n'
        )
        lines = [
            l
            for l in log.splitlines()
            if 'DEMO LIFECYCLE' in l
            or 'SUPPORT FACE' in l
            or 'script' in l.lower()
            and 'error' in l.lower()
        ]
        print(mapname + '\n' + '\n'.join(lines) + '\nEvidence: ' + str(home), flush=True)
        assert (
            'DEMO LIFECYCLE COMPLETE failures=0' in log
            and 'script compile error' not in log
            and 'script runtime error' not in log
        ), home
    finally:
        subprocess.run(['docker', 'rm', '-f', name], capture_output=True)
