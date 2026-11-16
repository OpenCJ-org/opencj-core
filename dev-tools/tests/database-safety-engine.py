"""Real GSC regressions and restricted-account startup on the safety fixture."""
from pathlib import Path
import hashlib,json,re,shutil,subprocess,sys,time
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/"server-db/tools"))
from mysql_session import MySQL
home=Path(sys.argv[1]).resolve()
assert home.parent==ROOT/"dev-tools/local" and re.fullmatch(r"database-safety-[0-9a-f]{8}",home.name)
fixture=json.loads((home/"fixture.json").read_text())
name=fixture["container"];assert name=="opencj-"+home.name
database=fixture["database"];assert database=="route_fixture_cod4"
private=Path(fixture["private"]);assert private==home/"mysql.env"
password=next(line.split("=",1)[1] for line in private.read_text().splitlines() if line.startswith("MYSQL_ROOT_PASSWORD="))
engine=name+"-engine";started=False
report={"liveDatabaseWrites":False}
def run(args,**kw):return subprocess.run(args,capture_output=True,text=True,**kw)
def launch(user,marker):
    global started
    cfg=mod/"safety.cfg"
    cfg.write_text(f'set db_host "{name}"\nset db_user "{user}"\nset db_pass "{password}"\nset db_base "{database[:-1]}"\nset db_port "3306"\n');cfg.chmod(0o600)
    command=["docker","compose","run","-d","--no-deps","--name",engine,"server","/workspace/cod4x-server/bin/cod4x18_dedrun"]
    relative=str(home.relative_to(ROOT))
    for k,v in [("fs_basepath","/game"),("fs_homepath","/workspace/"+relative),("fs_game","mods/opencj"),("dedicated",2),("net_port",28978),("sv_maxclients",4),("sv_authorizemode",0),("com_hunkMegs",1024),("developer",1),("g_gametype","cj")]:
        command+=["+set",k,str(v)]
    command+=["+exec","safety.cfg","+map","mp_killhouse"]
    p=run(command,cwd=ROOT/"dev-tools");assert not p.returncode,p.stderr;started=True
    for _ in range(120):
        time.sleep(1);p=run(["docker","logs",engine]);log=(p.stdout+p.stderr).replace(password,"<redacted>")
        if any(x in log for x in [marker,"script compile error","script runtime error","Received signal:"]):break
    (home/(user+"-engine.log")).write_text(log)
    for line in log.splitlines():
        if any(x in line for x in ["SELFTEST COMPLETE","SELFTEST FAIL","SAFETY STARTUP","SQL ERROR"]):print(line,flush=True)
    assert marker in log and not any(x in log for x in ["script compile error","script runtime error"]),home/(user+"-engine.log")
    assert "SQL ERROR" not in log,home/(user+"-engine.log")
    assert not run(["docker","rm","-f",engine]).returncode;started=False
    return log
try:
    with MySQL(name,database) as db:
        db.query("CREATE USER 'fixture'@'%' IDENTIFIED BY '"+password+"'; GRANT ALL ON route_fixture_cod4.* TO 'fixture'@'%';")
    mod=home/"mods/opencj";mod.mkdir(parents=True)
    for folder in ["opencj","maps"]:shutil.copytree(ROOT/"server-gsc"/folder,mod/folder)
    for asset in ["mod.ff","z_opencj.iwd"]:(mod/asset).symlink_to("/mod-assets/"+asset)
    (home/"usermaps").symlink_to("/game/usermaps")
    (home/"plugins").mkdir()
    (home/"steamclient.so").symlink_to("/game/steamclient.so")
    shutil.copyfile(ROOT/"dev-tools/tests/checkpoints.gsc",mod/"opencj/safetytest.gsc")
    shutil.copyfile(ROOT/"dev-tools/tests/checkpoint-migration-db.gsc",mod/"opencj/route174migration.gsc")
    p=mod/"opencj/safetytest.gsc";s=p.read_text().replace('    printf("CPC SELFTEST COMPLETE',r'    openCJ\route174Migration::main();'+'\n    printf("CPC SELFTEST COMPLETE');p.write_text(s)
    init=mod/"opencj/events/init.gsc"
    original=init.read_text()
    init.write_text(original.replace('    thread _everyFrame();','    setDvar("g_FFAPlayerCanBlock",1);\n'+r'    thread openCJ\safetyTest::main();'+'\n    thread _everyFrame();'))
    p=mod/"opencj/camera.gsc";p.write_text(p.read_text().replace(r'    self openCJ\clientInit::waitUntilFinished();','    return; // Synthetic clients do not acknowledge startup.'))
    log=launch("fixture","CPC SELFTEST COMPLETE failures=0")
    report["checkpointChecks"]=log.count("CPC SELFTEST PASS:")
    assert "MIGRATION SELFTEST COMPLETE failures=0" in log
    report["historyChecks"]=log.count("MIGRATION SELFTEST PASS")
    init.write_text(original.replace('    thread _everyFrame();',r'    thread openCJ\safetyStartup::main();'+'\n    thread _everyFrame();'))
    (mod/"opencj/safetystartup.gsc").write_text(r"""
main()
{
    for(i=0;i<100 && !level.challengesReady;i++)wait 0.1;
    if(!level.challengesReady){printf("SAFETY STARTUP FAIL challenges\n");return;}
    rows=openCJ\mySQL::mysqlSyncQuery("SELECT COUNT(*) FROM playerDisplayNames");
    if(!isDefined(rows)){printf("SAFETY STARTUP FAIL names\n");return;}
    rows=openCJ\mySQL::mysqlSyncQuery("SELECT COUNT(*) FROM schemaMigrations WHERE state='applied'");
    if(!isDefined(rows) || int(rows[0][0])!=3){printf("SAFETY STARTUP FAIL migrations\n");return;}
    printf("SAFETY STARTUP COMPLETE restricted account\n");
}
""")
    launch("opencj","SAFETY STARTUP COMPLETE restricted account")
    report["restrictedStartup"]=True
    report["sourceHashes"]={str(p.relative_to(ROOT/"server-gsc")):hashlib.sha256(p.read_bytes()).hexdigest() for p in (ROOT/"server-gsc/opencj").rglob("*.gsc")}
    report["migrationHashes"]={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in (ROOT/"server-db/migrations").glob("02[123]-*.sql")}
    report["passed"]=True
finally:
    if started:run(["docker","rm","-f",engine])
    (home/"mods/opencj/safety.cfg").unlink(missing_ok=True)
    report["databaseRemoved"]=run(["docker","rm","-f","-v",name]).returncode==0
    private.unlink(missing_ok=True)
    (home/"engine-result.json").write_text(json.dumps(report,indent=2)+"\n")
    print("SAFE_ENGINE_RESULT "+str(home/"engine-result.json"),flush=True)
