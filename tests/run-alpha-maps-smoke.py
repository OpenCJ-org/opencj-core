"""Run alpha-map regression fixtures on isolated servers; no database or live players."""
from pathlib import Path
import shutil,subprocess,time,uuid,sys
root=Path(__file__).resolve().parents[2]
routes='--routes' in sys.argv
menu_only='--menu-only' in sys.argv or routes
for mapname in [a for a in sys.argv[1:] if a not in ['--menu-only', '--routes']] or ['mp_dark']:
    assert mapname in ['mp_dark', 'mp_bouncer_training', 'mp_blue2', 'mp_descent_v2', 'mp_galaxy', 'mp_mystic_v3'], 'No acceptance fixture for this map'
    tag='alpha-maps-'+uuid.uuid4().hex[:8]
    home=root/'dev-tools/local'/tag
    mod=home/'mods/opencj';mod.mkdir(parents=True)
    for name in ['opencj','maps']:shutil.copytree(root/'server-gsc'/name,mod/name)
    if mapname == 'mp_dark' and not menu_only:
        # Read only published map geometry. Engine tests never connect to the DB.
        import json
        sql="""USE openCJ_cod4; START TRANSACTION READ ONLY;
    SELECT 'AREA',c.cpID,c.onGround,c.allowSave,COALESCE(c.ender,''),a.routeName,a.ordinal,a.vertices,a.allowDoubleRPG,COALESCE(a.heightAbove,0)
    FROM checkpoints c JOIN checkpointAreas a ON a.cpID=c.cpID JOIN mapids m ON m.mapID=c.mapID
    WHERE m.mapname='mp_dark' AND c.retired=0 ORDER BY a.routeName,a.ordinal,c.cpID;
    SELECT 'EDGE',cc.cpID,cc.childcpID FROM checkpointConnections cc JOIN checkpoints c ON c.cpID=cc.cpID JOIN mapids m ON m.mapID=c.mapID
    WHERE m.mapname='mp_dark' AND c.retired=0; COMMIT;"""
        cmd=['docker','compose','exec','-T','db','sh','-c','MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot -N -B']
        snapshot=subprocess.run(cmd,cwd=root/'dev-tools',input=sql,capture_output=True,text=True,check=True).stdout
        (home/'published-checkpoints.tsv').write_text(snapshot)
        records={};edges=[]
        for line in snapshot.splitlines():
            values=line.split('\t')
            if values[0]=='AREA':records[int(values[1])]=values[1:]
            elif values[0]=='EDGE':edges.append(tuple(map(int,values[1:])))
        assert len(records)==167, 'Published layout changed: review and update acceptance evidence'
        assert all(a in records and b in records for a,b in edges), 'Dangling checkpoint connection'
        assert all(records[a][4]==records[b][4] for a,b in edges), 'Cross-route connection'
        graph={}
        for route in ['easy','hard']:
            ids={key for key,v in records.items() if v[4]==route}
            es=[(a,b) for a,b in edges if a in ids]
            starts=ids-{b for a,b in es};ends={key for key in ids if records[key][3]}
            assert len(starts)==1 and len(ends)==1,(route,starts,ends)
            def visit(start, reverse=False):
                seen=set();todo=list(start)
                while todo:
                    current=todo.pop()
                    if current in seen:continue
                    seen.add(current)
                    todo.extend(a if reverse else b for a,b in es if (b if reverse else a)==current)
                return seen
            assert visit(starts)==ids and visit(ends,True)==ids,route
            assert all(int(records[a][5])<int(records[b][5]) for a,b in es), 'Backward/cyclic connection'
            graph[route]={'checkpoints':len(ids),'start':next(iter(starts)),'finish':next(iter(ends)),'edges':len(es)}
        (home/'graph-report.json').write_text(json.dumps(graph,indent=2))
        print('Published graph: '+json.dumps(graph),flush=True)
        data=['areas()','{','    result = [];']
        for key,v in records.items():
            data+=['    cp = spawnStruct();',f'    cp.id = {key}; cp.onGround = {v[1]}; cp.allowSave = {v[2]}; cp.heightAbove = {v[8]};',
                   '    cp.encoded = '+json.dumps(v[6])+';','    result[result.size] = cp;']
        data+=['    return result;','}']
        (mod/'opencj/alphaauditdata.gsc').write_text('\n'.join(data)+'\n')
    for name in ['mod.ff','z_opencj.iwd']:(mod/name).symlink_to('/mod-assets/'+name)
    (home/'usermaps').symlink_to('/game/usermaps')
    (home/'plugins').mkdir()
    (home/'plugins/libcod4_1_8x.so').symlink_to('/workspace/dev-tools/local/runtime/plugins/libcod4_1_8x.so')
    (home/'steamclient.so').symlink_to('/game/steamclient.so')
    fixtures = {'mp_dark': 'alpha-maps.gsc', 'mp_bouncer_training': 'alpha-bouncer-training.gsc', 'mp_blue2': 'alpha-blue2.gsc', 'mp_descent_v2': 'alpha-descent-v2.gsc', 'mp_galaxy': 'alpha-galaxy.gsc', 'mp_mystic_v3': 'alpha-mystic-v3.gsc'}
    fixture = 'alpha-map-menu.gsc' if menu_only else fixtures[mapname]
    shutil.copyfile(root/'dev-tools/tests'/fixture,mod/'opencj/platformtest.gsc')
    shutil.copyfile(root/'dev-tools/tests/alpha-map-data.gsc',mod/'opencj/alphamapdata.gsc')
    if routes:
        subprocess.run([sys.executable,str(root/'dev-tools/tests/check-map-routes.py'),str(home)],check=True)
        shutil.copyfile(home/'maproutecataloguedata.gsc',mod/'opencj/maproutecataloguedata.gsc')
        shutil.copyfile(root/'dev-tools/tests/map-routes.gsc',mod/'opencj/maproutestest.gsc')
        test=mod/'opencj/platformtest.gsc'
        source=test.read_text().replace('    finish();\n}', '    openCJ\\mapRoutesTest::run(player);\n    finish();\n}',1)
        test.write_text(source)

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
    if mapname == 'mp_galaxy' and not menu_only:
        # Capture map text without changing listener control flow.
        galaxy = mod/'maps/mp/mp_galaxy.gsc'
        galaxy.write_text(re.sub(r'(?i)\biprintln(?:bold)?\s*\(', r'openCJ\\platformTest::captureMessage(', galaxy.read_text()))
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
