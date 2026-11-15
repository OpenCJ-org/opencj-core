"""Run demo timeline regression fixtures on isolated servers; no database or live players."""
from pathlib import Path
import argparse,shutil,subprocess,time,uuid,sys
root=Path(__file__).resolve().parents[2]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('maps',nargs='*',default=['mp_dark'])
parser.add_argument('--binary',default='/workspace/cod4x-server/bin/cod4x18_demo_test')
options=parser.parse_args()
for mapname in options.maps or ['mp_dark']:
    tag='demo-timelines-'+uuid.uuid4().hex[:8]
    home=root/'dev-tools/local'/tag
    mod=home/'mods/opencj';mod.mkdir(parents=True)
    for name in ['opencj','maps']:shutil.copytree(root/'server-gsc'/name,mod/name)
    for name in ['mod.ff','z_opencj.iwd']:(mod/name).symlink_to('/mod-assets/'+name)
    (home/'usermaps').symlink_to('/game/usermaps')
    (home/'plugins').mkdir()

    (home/'steamclient.so').symlink_to('/game/steamclient.so')
    shutil.copyfile(root/'dev-tools/tests/demo-timelines.gsc',mod/'opencj/platformtest.gsc')
    shutil.copyfile(root/'dev-tools/tests/demo-selection.gsc',mod/'opencj/demoselectiontest.gsc')
    init=mod/'opencj/events/init.gsc';s=init.read_text();init.write_text(s.replace('    level.playerCount = 0;', '    return;\n    level.playerCount = 0;',1))
    game=mod/'maps/mp/gametypes/cj.gsc';s=game.read_text();game.write_text(s.replace('main()\n{','main()\n{\n    thread openCJ'+chr(92)+'platformTest::main();',1))
    # Test clients must not reach account/database callbacks in this isolated fixture.
    callback=mod/'maps/mp/gametypes/_callbacksetup.gsc'
    import re
    source=re.sub(r'//[^\n]*','',callback.read_text())
    import re
    matches=list(re.finditer(r'(CodeCallback_\w+)\([^)]*\)\s*\{',source))
    for match in reversed(matches):
        if match.group(1)=='CodeCallback_FragButton': continue
        start=match.end();end=start;depth=1
        while depth:
            if source[end]=='{': depth+=1
            elif source[end]=='}': depth-=1
            end+=1
        source=source[:start]+'\n'+source[end-1:]
    callback.write_text(source)
    name='opencj-'+tag
    args=['docker','compose','run','-d','--no-deps','--name',name,'server',options.binary]
    for k,v in [('fs_basepath','/game'),('fs_homepath','/workspace/dev-tools/local/'+tag),('fs_game','mods/opencj'),('dedicated','2'),('net_port','28963'),('sv_maxclients','1'),('sv_authorizemode','0'),('com_hunkMegs','1024'),('developer','1'),('g_gametype','cj'),('opencj_isolated_demo_test','1')]:args+=['+set',k,v]
    args+=['+map',mapname]
    try:
        subprocess.run(args,cwd=root/'dev-tools',check=True,capture_output=True)
        for _ in range(45):
            time.sleep(1)
            log=subprocess.check_output(['docker','logs',name],stderr=subprocess.STDOUT,text=True)
            if 'DEMO TIMELINE COMPLETE' in log or 'script compile error' in log or 'script runtime error' in log:break
        if 'script compile error' in log or 'script runtime error' in log:
            pos=log.index('script compile error') if 'script compile error' in log else log.index('script runtime error');print(log[pos:pos+1400],flush=True)
        (home/'console.log').write_text(log)
        lines=[l for l in log.splitlines() if 'DEMO TIMELINE' in l or 'DEMO SELECTION' in l and 'QUERY' not in l or 'SUPPORT FACE' in l or 'script' in l.lower() and 'error' in l.lower()]
        print(mapname+'\n'+'\n'.join(lines)+'\nEvidence: '+str(home),flush=True)
        assert 'DEMO TIMELINE COMPLETE failures=0' in log,home
    finally:subprocess.run(['docker','rm','-f',name],capture_output=True)
