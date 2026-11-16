"""Run collision regression fixtures on isolated servers; no database or live players."""
from pathlib import Path
import shutil,subprocess,time,uuid,sys
root=Path(__file__).resolve().parents[2]
moving='--moving' in sys.argv
fixture='platform-moving.gsc' if moving else 'platform-brushes.gsc'
alternatives='--alternatives' in sys.argv
if alternatives: fixture='checkpoint-alternatives.gsc'
height='--height' in sys.argv
if height: fixture='checkpoint-height.gsc'
insertion='--insert' in sys.argv
if insertion: fixture='checkpoint-insert.gsc'
maps=[arg for arg in sys.argv[1:] if arg not in ['--moving','--alternatives','--height','--insert']]
if insertion and not maps: maps=['mp_dark']
if height and not maps: maps=['mp_dark']
if alternatives and not maps: maps=['mp_dark']
if moving and not maps: maps=['mp_qube']
for mapname in maps or ['mp_to_the_moon','mp_mystic_v3','mp_mystic_v2','mp_galaxy','mp_dark','mp_futile_fixed','mp_blue2']:
    tag='platform-support-'+uuid.uuid4().hex[:8]
    home=root/'dev-tools/local'/tag
    mod=home/'mods/opencj';mod.mkdir(parents=True)
    for name in ['opencj','maps']:shutil.copytree(root/'server-gsc'/name,mod/name)
    for name in ['mod.ff','z_opencj.iwd']:(mod/name).symlink_to('/mod-assets/'+name)
    (home/'usermaps').symlink_to('/game/usermaps')
    (home/'plugins').mkdir()

    (home/'steamclient.so').symlink_to('/game/steamclient.so')
    shutil.copyfile(root/'dev-tools/tests'/fixture,mod/'opencj/platformtest.gsc')
    init=mod/'opencj/events/init.gsc';s=init.read_text();init.write_text(s.replace('    level.playerCount = 0;', '    return;\n    level.playerCount = 0;',1))
    game=mod/'maps/mp/gametypes/cj.gsc';s=game.read_text();game.write_text(s.replace('main()\n{','main()\n{\n    thread openCJ'+chr(92)+'platformTest::main();',1))
    name='opencj-'+tag
    args=['docker','compose','run','-d','--no-deps','--name',name,'server','/workspace/cod4x-server/bin/cod4x18_dedrun']
    for k,v in [('fs_basepath','/game'),('fs_homepath','/workspace/dev-tools/local/'+tag),('fs_game','mods/opencj'),('dedicated','2'),('net_port','28963'),('sv_maxclients','1'),('sv_authorizemode','0'),('com_hunkMegs','1024'),('developer','1'),('g_gametype','cj')]:args+=['+set',k,v]
    args+=['+map',mapname]
    try:
        subprocess.run(args,cwd=root/'dev-tools',check=True,capture_output=True)
        for _ in range(45):
            time.sleep(1)
            log=subprocess.check_output(['docker','logs',name],stderr=subprocess.STDOUT,text=True)
            if 'BRUSH SELFTEST COMPLETE' in log or 'script compile error' in log or 'script runtime error' in log:break
        (home/'console.log').write_text(log)
        lines=[l for l in log.splitlines() if 'SELFTEST' in l or 'SUPPORT FACE' in l or 'script' in l.lower() and 'error' in l.lower()]
        print(mapname+'\n'+'\n'.join(lines),flush=True)
        assert 'BRUSH SELFTEST COMPLETE failures=0' in log,home
    finally:subprocess.run(['docker','rm','-f',name],capture_output=True)
