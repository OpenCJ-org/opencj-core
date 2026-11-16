"""Run chat-only camera tests on an isolated server; no production database writes or live players."""

from compose_environment import workspace_path
from pathlib import Path
import argparse
import shutil
import subprocess
import time
import uuid
import sys

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('maps', nargs='*', default=['mp_killhouse'])
parser.add_argument(
    '--binary',
    default=str(root / 'cod4x-server/bin/cod4x18_dedrun'),
    help='Matching current engine inside this checkout',
)
parser.add_argument(
    '--plugin', help='Optional matching probe inside this checkout; otherwise build from source'
)
options = parser.parse_args()
try:
    options.binary = workspace_path(options.binary)
    if options.plugin:
        options.plugin = workspace_path(options.plugin)
except ValueError as error:
    parser.error(str(error))
for mapname in options.maps or ['mp_killhouse']:
    tag = 'camera-' + uuid.uuid4().hex[:8]
    home = root / 'dev-tools/local' / tag
    mod = home / 'mods/opencj'
    mod.mkdir(parents=True)
    for name in ['opencj', 'maps']:
        shutil.copytree(root / 'server-gsc' / name, mod / name)
    for name in ['mod.ff', 'z_opencj.iwd']:
        (mod / name).symlink_to('/mod-assets/' + name)
    (home / 'usermaps').symlink_to('/game/usermaps')
    (home / 'plugins').mkdir()

    (home / 'steamclient.so').symlink_to('/game/steamclient.so')
    shutil.copyfile(root / 'dev-tools/tests/camera.gsc', mod / 'opencj/platformtest.gsc')
    # Real older OCJ4 wire payload: no newly recorded animation metadata.
    import struct
    import zlib

    frames = []
    cases = [
        (8192 | 512, 0, 0, 0),
        (8192 | 512 | 4, 90, 0, 0),
        (8192 | 512 | 4, 190, 0, 0),
        (8192 | 512 | 4 | 64, 280, 0, 0),
        (8192 | 512 | 8, -190, 0, 0),
        (8192 | 512 | 1, 0, 190, 0),
        (8192 | 512 | 2, 0, -190, 0),
        (8192 | 1024 | 4, 60, 0, 0),
        (8192 | 2048 | 4, 25, 0, 0),
        (512 | 256 | 4, 0, 0, 90),
        (512 | 4, 190, 0, 120),
    ]
    cases += [(8192 | 512 | 4, 190, 0, 0)] * 32  # Land, then resume running.
    cases += [(8192 | 2048 | 4, 25, 0, 0)] * 32  # Enter prone, then crawl.
    cases += [(8192 | 512, 0, 0, 0)] * 32  # Rise from prone, then stand.
    for flags, vx, vy, vz in cases:
        base = struct.pack('<3f3HHHiB', 0, 0, 100, 0, 0, 0, flags, 125, 17, 8)
        visual = bytearray(31)
        struct.pack_into('<h', visual, 8, 60 * 256)
        struct.pack_into('<3h', visual, 11, vx * 4, vy * 4, vz * 4)
        frames.append(base + visual + bytes([6]) + b'rpg_mp')
    chunks = [frames[i : i + 64] for i in range(0, len(frames), 64)]
    payloads = [
        zlib.compress(b'OCJ4' + struct.pack('<I', len(chunk)) + b''.join(chunk)).hex()
        for chunk in chunks
    ]
    decode = '+'.join('demoDecodeChunk(id,"' + payload + '")' for payload in payloads)
    fixture = mod / 'opencj/platformtest.gsc'
    fixture.write_text(
        fixture.read_text().replace('demoDecodeChunk(id,"BODY_FIXTURE_HEX")', decode)
    )

    settings = mod / 'opencj/settings.gsc'
    original = settings.read_text()
    needle = '    self thread writePlayerSettingToDb(name, self.settingValues[name]);'
    # Retain the real SQL builder, redirect only its final write call.
    sqlcall = '    self thread openCJ' + chr(92) + 'mySQL::mysqlAsyncQueryNosave(query);'
    assert original.count(sqlcall) == 1
    original = original.replace(sqlcall, '    level.cameraWrites[level.cameraWrites.size]=query;')
    loadcall = '    rows = self openCJ' + chr(92) + 'mySQL::mysqlAsyncQuery(query);'
    assert original.count(loadcall) == 1
    original = original.replace(loadcall, '    rows = level.cameraStoredRows;')
    original = original.replace(
        '    self openCJ' + chr(92) + 'events' + chr(92) + 'playerLogin::main();',
        '    // Account callbacks are outside this isolated setting fixture.',
    )
    settings.write_text(original)
    if options.plugin:
        (home / 'plugins/camera_engine.so').symlink_to(options.plugin)
    else:
        plugin_path = '/workspace/' + str(home.relative_to(root)) + '/plugins/camera_engine.so'
        subprocess.run(
            [
                'docker',
                'compose',
                'run',
                '--rm',
                '--no-deps',
                'build',
                'g++',
                '-m32',
                '-std=c++11',
                '-msse2',
                '-mfpmath=sse',
                '-fPIC',
                '-shared',
                '-DCOD4',
                '/workspace/dev-tools/tests/camera-engine.cpp',
                '-o',
                plugin_path,
            ],
            cwd=root / 'dev-tools',
            check=True,
            capture_output=True,
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
    import re

    source = re.sub(r'//[^\n]*', '', callback.read_text())
    import re

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
        ('net_port', '28974'),
        ('sv_maxclients', '2'),
        ('sv_authorizemode', '0'),
        ('com_hunkMegs', '1024'),
        ('developer', '1'),
        ('g_gametype', 'cj'),
        ('opencj_isolated_camera_test', '1'),
        ('cg_thirdPerson', '1'),
    ]:
        args += ['+set', k, v]
    args += ['+loadplugin', 'camera_engine', '+map', mapname]
    try:
        subprocess.run(args, cwd=root / 'dev-tools', check=True, capture_output=True)
        for _ in range(45):
            time.sleep(1)
            log = subprocess.check_output(
                ['docker', 'logs', name], stderr=subprocess.STDOUT, text=True
            )
            if (
                ('CAMERA TEST COMPLETE' in log and 'CAMERA NATIVE COMPLETE' in log)
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
        lines = [
            l
            for l in log.splitlines()
            if 'CAMERA' in l
            and 'SQL' not in l
            or 'SUPPORT FACE' in l
            or 'script' in l.lower()
            and 'error' in l.lower()
        ]
        print(mapname + '\n' + '\n'.join(lines) + '\nEvidence: ' + str(home), flush=True)
        assert (
            'CAMERA TEST COMPLETE failures=0' in log and 'CAMERA NATIVE COMPLETE failures=0' in log
        ), home
    finally:
        subprocess.run(['docker', 'rm', '-f', name], capture_output=True)
