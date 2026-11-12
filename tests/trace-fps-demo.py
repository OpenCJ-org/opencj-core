"""Replay an existing exported demo through the HUD, logging actions and displayed text.

Usage: python3 tests/trace-fps-demo.py <run-id> before
Or pass an exported JSON file with runID and [chunkNum, hexPayload] chunks.
A numeric argument reads that demo's chunks from the OpenCJ DB using SELECT.
No production writes, network ports, or human clients are used.
"""
from pathlib import Path
import sys,json,subprocess,shutil,time,re,uuid,hashlib
root=Path(__file__).resolve().parents[2]
if sys.argv[1].isdigit():
    run_id=int(sys.argv[1])
    query="SELECT chunkNum,HEX(payload) FROM demoChunks WHERE runID="+str(run_id)+" ORDER BY chunkNum;"
    cmd=["docker","exec","-i","opencj-dev-db-1","sh","-c",'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -N -u root openCJ_cod4']
    result=subprocess.run(cmd,input=query,text=True,capture_output=True)
    assert result.returncode==0,"Read-only demo export failed"
    recording={"runID":run_id,"chunks":[line.split("\t") for line in result.stdout.splitlines()]}
    assert recording["chunks"],"No stored chunks found for this run"
else:
    recording=json.loads(Path(sys.argv[1]).read_text())
label=sys.argv[2]
assert re.fullmatch(r"[a-z0-9_-]+",label)
tag="fps-live-trace-"+label+"-"+uuid.uuid4().hex[:8]
home=root/"dev-tools/local"/tag;mod=home/"mods/opencj";mod.mkdir(parents=True)
(home/"recording.json").write_text(json.dumps(recording)+"\n")
(home/"recording.json").chmod(0o600)
for folder in ["maps","opencj"]:shutil.copytree(root/"server-gsc"/folder,mod/folder)
for asset in ["mod.ff","z_opencj.iwd"]:(mod/asset).symlink_to("/mod-assets/"+asset)
(home/"usermaps").symlink_to("/game/usermaps")
(home/"steamclient.so").symlink_to("/game/steamclient.so")
(home/"plugins").mkdir()
(home/"plugins/libcod4_1_8x.so").symlink_to("/workspace/dev-tools/local/runtime/plugins/libcod4_1_8x.so")
init=mod/"opencj/events/init.gsc";init.write_text(init.read_text().replace("    level.playerCount = 0;","    return;\n    level.playerCount = 0;",1))
game=mod/"maps/mp/gametypes/cj.gsc";game.write_text(game.read_text().replace("main()\n{","main()\n{\n    thread openCJ\\platformTest::main();",1))
callback=mod/"maps/mp/gametypes/_callbacksetup.gsc"
source=re.sub(r"//[^\n]*","",callback.read_text())
for match in reversed(list(re.finditer(r"(CodeCallback_\w+)\([^)]*\)\s*\{",source))):
    start=match.end();end=start;depth=1
    while depth:
        if source[end]=="{":depth+=1
        elif source[end]=="}":depth-=1
        end+=1
    source=source[:start]+"\n"+source[end-1:]
callback.write_text(source)
hud=mod/"opencj/huds/hudfpshistory.gsc"
source=hud.read_text()
source=source.replace("getTime()","level.fpsTraceTime")
needle="    event.switched=switched;event.started=now;"
assert needle in source
source=source.replace(needle,needle+'\n    printf("FPS LIVE ACTION\\t"+level.fpsTraceFrame+"\\t"+level.fpsTraceTime+"\\t"+kind+"\\t"+event.keys+"\\t"+fps+"\\t"+switched+"\\n");')
hud.write_text(source)
fixture=r"""
main()
{
    level.fpsTraceTime=0;level.fpsTraceFrame=0;
    openCJ\settings::onInit();openCJ\commands_base::onInit();
    openCJ\huds\infiniteHuds::onInit();openCJ\huds\hudFPSHistory::onInit();
    wait 1;
    player=addTestClient();wait .2;
    player.sessionTeam="allies";player.sessionState="playing";player.pers["team"]="allies";
    player spawn((0,0,5000),(0,0,0));player.isFirstSpawn=false;
    player openCJ\huds\base::onPlayerConnect();
    player openCJ\huds\hudFPSHistory::onPlayerConnect();
    player.playingDemo=true;player.fpsHistoryMode="detailed";
    id=RUN_ID;
    createDemo(id);
    LOAD_CHUNKS
    completeDemo(id);player selectPlaybackDemo(id);
    range=player demoPlaybackStyle(2,0,numberOfDemoFrames(id)-1);
    player.demoBegin=range[0];player.demoEnd=range[1];
    first=true;previous=-2;tick=0;
    while(true)
    {
        skip=1;if(first)skip=0;
        frame=player openCJ\demos::_getDemoFrame(skip,true);
        level.fpsTraceFrame=frame.number;level.fpsTraceTime=tick*50;
        printf("FPS LIVE INPUT\t"+frame.number+"\t"+level.fpsTraceTime+"\t"+int(frame.forward)+"\t"+int(frame.back)+"\t"+int(frame.left)+"\t"+int(frame.right)+"\t"+int(frame.onGround)+"\t"+frame.FPS+"\t"+int(frame.bounce)+"\n");
        player openCJ\huds\hudFPSHistory::onDemoFrame(frame,!first && frame.number==previous+1,false);
        if(!isDefined(player.fpsTraceDetailed) || player.fpsTraceDetailed!=player.fpsHistoryDetailedText)
        {
            printf("FPS DETAILED HUD\t"+frame.number+"\t"+level.fpsTraceTime+"\t"+player.fpsHistoryDetailedText+"\n");
            player.fpsTraceDetailed=player.fpsHistoryDetailedText;
        }
        if(frame.number>=player.demoEnd)break;
        first=false;previous=frame.number;tick++;
        if(tick%40==0)wait .05;
    }
    printf("FPS LIVE TRACE COMPLETE frames="+(tick+1)+"\n");
}
"""
lines=[]
for nr,payload in recording["chunks"]:
    for start in range(0,len(payload),700):lines.append(payload[start:start+700])
    lines.append("END")
(mod/"trace-chunks.txt").write_text("\n".join(lines)+"\n")
loader=r"""
    file=FS_FOpen("trace-chunks.txt","read");chunk="";
    while(true)
    {
        line=FS_ReadLine(file);if(!isDefined(line))break;
        if(line=="END")
        {
            if(!isDefined(demoDecodeChunk(id,chunk)))printf("FPS LIVE DECODE ERROR\n");
            chunk="";
        }
        else chunk+=line;
    }
    FS_FClose(file);
"""
fixture=fixture.replace("RUN_ID",str(int(recording["runID"]))).replace("LOAD_CHUNKS",loader)
(mod/"opencj/platformtest.gsc").write_text(fixture)
name="opencj-"+tag
args=["docker","compose","run","-d","--no-deps","--name",name,"server","/workspace/cod4x-server/bin/cod4x18_dedrun"]
for k,v in [("fs_basepath","/game"),("fs_homepath","/workspace/dev-tools/local/"+tag),("fs_game","mods/opencj"),("dedicated","2"),("net_port","28967"),("sv_maxclients","1"),("sv_authorizemode","0"),("com_hunkMegs","1024"),("developer","1"),("g_gametype","cj")]:args+=["+set",k,v]
args+=["+loadplugin","libcod4_1_8x","+map","mp_killhouse"]
try:
    subprocess.run(args,cwd=root/"dev-tools",check=True,capture_output=True)
    for _ in range(45):
        time.sleep(1)
        log=subprocess.check_output(["docker","logs",name],stderr=subprocess.STDOUT,text=True)
        if any(x in log for x in ["FPS LIVE TRACE COMPLETE","script runtime error","script compile error","FPS LIVE DECODE ERROR","Received signal:","script runtime warning"]):break
    assert "FPS LIVE TRACE COMPLETE" in log,log[-4000:]
    assert "script runtime error" not in log and "script compile error" not in log
    actions=[];detailed=[]
    for line in log.splitlines():
        if "FPS LIVE ACTION\t" in line:
            x=line[line.index("FPS LIVE ACTION\t"):].split("\t")
            actions.append({"frame":int(x[1]),"ms":int(x[2]),"kind":x[3],"keys":x[4],"fps":x[5],"switch":int(x[6])})
        if "FPS DETAILED HUD\t" in line:
            x=line[line.index("FPS DETAILED HUD\t"):].split("\t")
            detailed.append({"frame":int(x[1]),"ms":int(x[2]),"text":x[3]})
    result={"runID":recording["runID"],"label":label,"sourceSha256":hashlib.sha256((root/"server-gsc/opencj/huds/hudfpshistory.gsc").read_bytes()).hexdigest(),"actions":actions,"detailedChanges":detailed}
    (home/"trace.json").write_text(json.dumps(result,indent=2)+"\n")
    print(json.dumps({"path":str(home/"trace.json"),"actions":len(actions),"detailedChanges":len(detailed),"switches":sum(a["switch"] for a in actions),"rawNeutralActions":sum(a["keys"]=="None" and a["kind"]=="move" for a in actions)},indent=2))
finally:
    logs=subprocess.run(["docker","logs",name],capture_output=True,text=True)
    (home/"console.log").write_text(logs.stdout+logs.stderr)
    subprocess.run(["docker","rm","-f",name],capture_output=True)
