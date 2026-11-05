"""Test installed map catalogue and voting menus on an isolated server; no database or live players."""
from pathlib import Path
import shutil,subprocess,time,uuid,sys
root=Path(__file__).resolve().parents[2]
menu_only=True
for mapname in [a for a in sys.argv[1:] if a not in ['--menu-only']] or ['mp_dark']:
    assert mapname.startswith('mp_') and all(c.isalnum() or c == '_' for c in mapname)
    tag='alpha-maps-'+uuid.uuid4().hex[:8]
    home=root/'dev-tools/local'/tag
    mod=home/'mods/opencj';mod.mkdir(parents=True)
    for name in ['opencj','maps']:shutil.copytree(root/'server-gsc'/name,mod/name)
    for name in ['mod.ff','z_opencj.iwd']:(mod/name).symlink_to('/mod-assets/'+name)
    (home/'usermaps').symlink_to('/game/usermaps')
    (home/'plugins').mkdir()
    (home/'plugins/libcod4_1_8x.so').symlink_to('/workspace/dev-tools/local/runtime/plugins/libcod4_1_8x.so')
    (home/'steamclient.so').symlink_to('/game/steamclient.so')
    fixture = 'alpha-map-menu.gsc'
    shutil.copyfile(root/'dev-tools/tests'/fixture,mod/'opencj/platformtest.gsc')
    init=mod/'opencj/events/init.gsc';s=init.read_text();init.write_text(s.replace('    level.playerCount = 0;', '    return;\n    level.playerCount = 0;',1))
    game=mod/'maps/mp/gametypes/cj.gsc';s=game.read_text();game.write_text(s.replace('main()\n{','main()\n{\n    thread openCJ'+chr(92)+'platformTest::main();',1))
    # Test clients must not reach account/database callbacks in this isolated fixture.
    callback=mod/'maps/mp/gametypes/_callbacksetup.gsc'
    import re
    source=re.sub(r'//[^\n]*','',callback.read_text())
    matches=list(re.finditer(r'(CodeCallback_\w+)\([^)]*\)\s*\{',source))
    for match in reversed(matches):
        if match.group(1)=='CodeCallback_FragButton': continue
        start=match.end();end=start;depth=1
        while depth:
            if source[end]=='{': depth+=1
            elif source[end]=='}': depth-=1
            end+=1
        # Keep the lifecycle notification used by production endon handlers,
        # while excluding account/database/disconnect side effects.
        body = '\n    self notify("disconnect");\n' if match.group(1)=='CodeCallback_PlayerDisconnect' else '\n'
        source=source[:start]+body+source[end-1:]
    callback.write_text(source)
    name='opencj-'+tag
    args=['docker','compose','run','-d','--no-deps','--name',name,'server','/workspace/cod4x-server/bin/cod4x18_dedrun']
    for k,v in [('fs_basepath','/game'),('fs_homepath','/workspace/dev-tools/local/'+tag),('fs_game','mods/opencj'),('dedicated','2'),('net_port','28971'),('sv_maxclients','2'),('sv_authorizemode','0'),('com_hunkMegs','1024'),('developer','1'),('g_gametype','cj')]:args+=['+set',k,v]
    args+=['+loadplugin','libcod4_1_8x','+map',mapname]
    try:
        subprocess.run(args,cwd=root/'dev-tools',check=True,capture_output=True)
        for _ in range(55):
            time.sleep(1)
            log=subprocess.check_output(['docker','logs',name],stderr=subprocess.STDOUT,text=True)
            if 'ALPHA SELFTEST COMPLETE' in log or 'script compile error' in log or 'script runtime error' in log:break
        if 'script compile error' in log or 'script runtime error' in log:
            pos=log.index('script compile error') if 'script compile error' in log else log.index('script runtime error');print(log[pos:pos+1400],flush=True)
        lines=[l for l in log.splitlines() if 'SELFTEST' in l or 'SUPPORT FACE' in l or 'script' in l.lower() and 'error' in l.lower()]
        print(mapname+'\n'+'\n'.join(lines),flush=True)
        assert 'ALPHA SELFTEST COMPLETE failures=0' in log,home
        for error in ['script compile error','script runtime error','Reliable command is too long','MSG_WriteString: MAX_STRING_CHARS','EXE_SERVERCOMMANDOVERFLOW']:
            assert error not in log,(error,home)
    finally:
        logs=subprocess.run(['docker','logs',name],capture_output=True,text=True)
        (home/'console.log').write_text(logs.stdout+logs.stderr)
        print('Test log: '+str(home/'console.log'),flush=True)
        subprocess.run(['docker','rm','-f',name],capture_output=True)
