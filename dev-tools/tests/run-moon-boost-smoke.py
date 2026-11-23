"""Isolated native bot regression: live movement, production lifecycle handlers,
fixture account/UI/database dependencies. Never connects to the real database."""

from pathlib import Path
import shutil
import subprocess
import time
import uuid
import re
import json

root = Path(__file__).resolve().parents[2]
tag = 'moon-boost-' + uuid.uuid4().hex[:8]
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
# Replace only service dependencies in this isolated copy. Keep the complete
# production handlers for actual loads, spectator/spawn, and run restoration.
keep = {
    'mapboost': None,
    'events/loadposition': {'main'},
    'events/spawnspectator': {'main'},
    'events/spawnplayer': {'main'},
    'events/eventhandler': {'onLoadPositionRequest'},
    'events/playerkilled': {'main'},
    'noclip': {'hasNoclip', 'enableNoclip', 'disableNoclip'},
    'checkpointcreation': {
        'isEditing',
        'processTravelRequests',
        'loadPosition',
        'rememberPosition',
    },
    'playerruns': {
        'restoreRun', 'setRunIDAndInstanceNumber', 'getRunID',
        'getRunInstanceNumber', 'hasRunID', 'isRunFinished',
        '_canAccessRuns', '_invalidatePendingCreation',
    },
    'historysave': None,
}
custom = {
    ('playerruns', 'archiveRun'): 'self.testArchivedRunID = runID; return;',
    ('login', 'isLoggedIn'): 'return true;',
    ('settings', 'areSettingsLoaded'): 'return true;',
    ('settings', 'getSetting'): 'return false;',
    ('shop', 'loadEquipment'): 'return true;',
    ('fpsregistration', 'canStart'): 'return true;',
    ('mapid', 'hasMapID'): 'return true;',
    ('util', 'isPlayerReady'): 'return true;',
    ('noclip', 'hasNoclip'): 'return self.noclip;',
    ('demos', 'isPlayingDemo'): 'return self.playingDemo;',
    ('saveposition', 'getSavedPosition'): 'return self.testSaves[backwardsAmount];',
    ('saveposition', 'canLoadError'): 'return int(self.testNoSaves);',
    ('saveposition', 'incrementBackwardsCount'): 'return amount;',
    ('spawnpoints', 'getPlayerSpawnpoint'): 'return self.testSpawn;',
    ('spawnpoints', 'getSpectatorSpawnpoint'): 'return self.testSpawn;',

}

# Match the current read/write wrapper contract: a SELECT returns rows, never a
# scalar status. Keep the real bounded history loader for empty-run relocation.
history_rows = """
    if(isDefined(self) && isDefined(self.testHistoryFailure) && self.testHistoryFailure)
    {
        return undefined;
    }
    rows = [];
    if(isSubStr(query, "SELECT s.saveNumber"))
    {
        return rows;
    }
    row = [];
    row[0] = 1;
    row[1] = 0;
    row[2] = 0;
    row[3] = 0;
    rows[0] = row;
    return rows;
"""
for function in ("mysqlAsyncQuery", "mysqlAsyncRead", "mysqlAsyncWrite"):
    custom[("mysql", function)] = history_rows


# Replace bodies using a comment/string-aware mask so braces in strings or
# comments cannot corrupt the production signatures.
def bodies(src):
    mask = re.sub(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"', lambda m: ' ' * (len(m[0])), src)
    found = list(re.finditer(r'^(\w+)\(([^)]*)\)\s*\{', mask, re.M))
    for m in reversed(found):
        end = m.end()
        depth = 1
        while depth:
            if mask[end] == '{':
                depth += 1
            elif mask[end] == '}':
                depth -= 1
            end += 1
        yield m.group(1), m.group(2), m.end(), end - 1


for p in (mod / 'opencj').rglob('*.gsc'):
    key = str(p.relative_to(mod / 'opencj').with_suffix('')).lower()
    if key in keep and keep[key] is None:
        continue
    s = p.read_text()
    for fn, args, start, end in bodies(s):
        if fn in keep.get(key, set()):
            continue
        body = custom.get((key, fn), 'return 0;')
        # Match actual production parameter names for fixture-only service results.
        if key == 'saveposition' and fn == 'getSavedPosition':
            body = 'return self.testSaves[' + args.split(',')[0].strip() + '];'
        if key == 'mysql' and fn in ('mysqlAsyncQuery', 'mysqlAsyncRead', 'mysqlAsyncWrite'):
            body = body.replace('query,', args.split(',')[0].strip() + ',')
        s = s[:start] + '\n' + body + '\n' + s[end:]
    p.write_text(s)
# Run restore with saved positions exercises real restoreRun/loadPosition. Empty
# restores additionally exercise real historyLoad/_loadSavesFromDatabase.
p = mod / 'opencj/historysave.gsc'
s = p.read_text()
s = s.replace(
    '    self openCJ\\mapBoost::cancel();',
    '    self openCJ\\mapBoost::cancel();\n    if(!self.testNoSaves)return true;',
    1,
)
p.write_text(s)
# Observe every real scale write, without replacing the native setter.
p = mod / 'opencj/mapboost.gsc'
s = p.read_text()
s = re.sub(
    r'self SetMoveSpeedScale\(([^)]+)\);', r'self.testScale=\1;self SetMoveSpeedScale(\1);', s
)
p.write_text(s)
p = mod / 'maps/mp/mp_to_the_moon.gsc'
s = p.read_text()
for fn in ['speed', 'speed2', 'speed3']:
    s = s.replace('thread ' + fn + '();', '')
    s = s.replace(fn + '()\n{', fn + '()\n{\n    level endon("moon_test_stop_listener");')
p.write_text(s)
shutil.copyfile(root / 'dev-tools/tests/moon-boost.gsc', mod / 'opencj/moonboosttest.gsc')
p = mod / 'maps/mp/gametypes/cj.gsc'
s = p.read_text()
p.write_text(s.replace('main()\n{', 'main()\n{\n    thread openCJ\\moonBoostTest::main();', 1))
p = mod / 'maps/mp/gametypes/_callbacksetup.gsc'
s = p.read_text()
for fn, args, start, end in bodies(s):
    if fn.startswith('CodeCallback_'):
        s = s[:start] + '\n' + s[end:]
p.write_text(s)
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
    '/workspace/cod4x-server/bin/cod4x18_dedrun',
]
for k, v in [
    ('fs_basepath', '/game'),
    ('fs_homepath', '/workspace/dev-tools/local/' + tag),
    ('fs_game', 'mods/opencj'),
    ('dedicated', '2'),
    ('net_port', '28963'),
    ('sv_maxclients', '4'),
    ('sv_authorizemode', '0'),
    ('com_hunkMegs', '1024'),
    ('developer', '1'),
    ('g_gametype', 'cj'),
    ('sv_fps', '20'),
]:
    args += ['+set', k, v]
args += ['+map', 'mp_to_the_moon']
try:
    subprocess.run(args, cwd=root / 'dev-tools', check=True, capture_output=True)
    for _ in range(70):
        time.sleep(1)
        log = subprocess.check_output(['docker', 'logs', name], stderr=subprocess.STDOUT, text=True)
        if (
            'MOON SELFTEST COMPLETE' in log
            or 'script compile error' in log
            or 'script runtime error' in log
        ):
            break
    (home / 'test.log').write_text(log)
    for l in log.splitlines():
        if 'MOON SELFTEST' in l:
            print(l, flush=True)
    for term in ['script compile error', 'script runtime error']:
        if term in log:
            pos = log.index(term)
            print(log[pos : pos + 2200], flush=True)
    print('ARTIFACTS', home, flush=True)
    assert 'MOON SELFTEST COMPLETE failures=0' in log
finally:
    subprocess.run(['docker', 'rm', '-f', name], capture_output=True)
