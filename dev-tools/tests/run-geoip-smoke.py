"""Exercise GeoIP GSC in an isolated server using the currently deployed script/binary pair."""

from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('maps', nargs='*', default=['mp_killhouse'])
    parser.add_argument(
        '--asset-dir', type=Path, required=True, help='Matching compiled mod.ff and IWD directory'
    )
    parser.add_argument(
        '--scripts', type=Path, help='Exact prepared release; do not overlay working source'
    )
    args = parser.parse_args()
    for mapname in args.maps:
        tag = 'geoip-smoke-' + uuid.uuid4().hex[:8]
        home = ROOT / 'dev-tools/local' / tag
        mod = home / 'mods/opencj'
        mod.mkdir(parents=True)
        runtime = ROOT / 'dev-tools/local/runtime/mods/opencj'
        links = {}
        for name in ['opencj', 'maps']:
            src = (args.scripts or runtime) / name
            if src.is_symlink():
                links[name] = str(src.readlink())
                src = Path(links[name].replace('/workspace', str(ROOT), 1))
            shutil.copytree(src, mod / name)
        if not args.scripts:
            for name in ['country.gsc', 'flagatlas.gsc', 'scoreboard.gsc']:
                shutil.copy2(ROOT / 'server-gsc/opencj' / name, mod / 'opencj' / name)
        assets = args.asset_dir.resolve()
        for name in ['mod.ff', 'z_opencj.iwd']:
            shutil.copy2(assets / name, mod / name)
        binary = home / 'cod4x18_geoip_smoke'
        shutil.copy2(ROOT / 'cod4x-server/bin/cod4x18_dedrun', binary)
        binary.chmod(0o755)
        (home / 'usermaps').symlink_to('/game/usermaps')
        (home / 'plugins').mkdir()

        (home / 'steamclient.so').symlink_to('/game/steamclient.so')
        shutil.copy2(ROOT / 'dev-tools/tests/geoip.gsc', mod / 'opencj/platformtest.gsc')
        init = mod / 'opencj/events/init.gsc'
        s = init.read_text()
        assert '    level.playerCount = 0;' in s
        init.write_text(
            s.replace('    level.playerCount = 0;', '    return;\n    level.playerCount = 0;', 1)
        )
        game = mod / 'maps/mp/gametypes/cj.gsc'
        s = game.read_text()
        game.write_text(
            s.replace('main()\n{', 'main()\n{\n    thread openCJ\\platformTest::main();', 1)
        )
        name = 'opencj-' + tag
        command = [
            'docker',
            'compose',
            'run',
            '-d',
            '--no-deps',
            '--name',
            name,
            "--workdir",
            "/workspace/" + str(home.relative_to(ROOT)),
            'server',
            '/workspace/dev-tools/local/' + tag + '/' + binary.name,
        ]
        for k, v in [
            ('fs_basepath', '/game'),
            ('fs_homepath', '/workspace/dev-tools/local/' + tag),
            ('fs_game', 'mods/opencj'),
            ('dedicated', '2'),
            ('net_port', '28976'),
            ('sv_maxclients', '1'),
            ('sv_authorizemode', '0'),
            ('com_hunkMegs', '1024'),
            ('developer', '1'),
            ('developer_script', '1'),
            ('g_gametype', 'cj'),
        ]:
            command += ['+set', k, v]
        command += ['+map', mapname]
        started = False
        try:
            subprocess.run(command, cwd=ROOT / 'dev-tools', check=True, capture_output=True)
            started = True
            log = ''
            for _ in range(50):
                time.sleep(1)
                log = subprocess.check_output(
                    ['docker', 'logs', name], stderr=subprocess.STDOUT, text=True
                )
                if (
                    'GEOIP SELFTEST COMPLETE' in log
                    or 'script compile error' in log
                    or 'script runtime error' in log
                ):
                    break
            (home / 'console.log').write_text(log)
            for token in ['script compile error', 'script runtime error']:
                if token in log:
                    pos = log.index(token)
                    print(log[max(0, pos - 200) : pos + 1400], flush=True)
            print(
                mapname,
                '\n'.join(line for line in log.splitlines() if 'GEOIP SELFTEST' in line),
                flush=True,
            )
            assert 'GEOIP SELFTEST COMPLETE failures=0' in log, str(home)
            (home / 'result.json').write_text(
                json.dumps(
                    {
                        'map': mapname,
                        'passed': True,
                        'runtime_links': links,
                        'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
                    },
                    indent=2,
                )
            )
        finally:
            if started:
                subprocess.run(['docker', 'rm', '-f', name], capture_output=True)


if __name__ == '__main__':
    main()
