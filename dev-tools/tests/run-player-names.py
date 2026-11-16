"""Verify preferred names and regular-name policy in a disposable DB/engine."""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import hashlib,json,re,shutil,subprocess,time,uuid
ROOT=Path(__file__).resolve().parents[2]
tag="player-names-"+uuid.uuid4().hex[:8]
database="opencj_verify_names_"+tag.rsplit("-",1)[1]+"_cod4"
assert re.fullmatch(r"opencj_verify_names_[0-9a-f]{8}_cod4",database)
home=ROOT/"dev-tools/local"/tag;mod=home/"mods/opencj";mod.mkdir(parents=True)
container="opencj-"+tag;created=granted=started=False;secrets=[]
report={"productionWrites":False,"checks":0,"failures":0}
def db(query,target=None):
    cmd=["docker","exec","-i","opencj-dev-db-1","sh","-c",'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -N -u root "$@"',"names103"]
    if target:
        assert target==database;cmd.append(target)
    p=subprocess.run(cmd,input=query,text=True,capture_output=True)
    if p.returncode:
        f=home/"sql-error.txt";f.write_text(p.stderr);f.chmod(0o600)
        raise RuntimeError("SQL test failed; inspect restricted "+str(f))
    return p.stdout.strip()
def check(ok,label):
    report["checks"]+=1
    if not ok:report["failures"]+=1
    print("NAME SQL CHECK "+str(int(bool(ok)))+": "+label,flush=True)
def redact(text):
    for value in secrets:
        if value:text=text.replace(value,"<redacted>")
    return text
try:
    assert db("SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='"+database+"';")=="0"
    dump=subprocess.run(["docker","exec","opencj-dev-db-1","sh","-c",'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump -u root --no-data --routines --triggers --skip-comments --skip-lock-tables --no-tablespaces --set-gtid-purged=OFF --column-statistics=0 openCJ_cod4'],capture_output=True,text=True)
    assert dump.returncode==0 and not re.search(r"^INSERT INTO",dump.stdout,re.M)
    db("CREATE DATABASE "+database+" CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;");created=True
    db(dump.stdout.replace("openCJ_cod4",database),database)
    db((ROOT/"server-db/migrations/017-preferred-names.sql").read_text(),database)
    db("GRANT ALL PRIVILEGES ON "+database+".* TO 'opencj'@'%';");granted=True
    db("INSERT INTO playerInformation(playerID,playerName,adminLevel) VALUES(1,'FixtureOne',0),(2,'FixtureTwo',0),(3,'Moderator',40),(4,'RaceOne',0),(5,'RaceTwo',0);",database)
    # Only harmless synthetic tokens are used in fixtures and test logs.
    db("INSERT INTO nameModerationRules(nameHash,normalizedLength,matchMode,source) VALUES(SHA2(normalizeModeratedName('FixtureToken'),256),LENGTH(normalizeModeratedName('FixtureToken')),'contains','test');"
       "INSERT INTO nameModerationExceptions SELECT ruleID,SHA2(normalizeModeratedName('OkFixtureToken'),256) FROM nameModerationRules WHERE source='test';",database)
    call=lambda pid,value:db("SELECT setPreferredName("+str(pid)+","+value+");",database)
    check(call(1,"'RecordName'")=="0","first preferred name accepted")
    check(call(2,"'recordname'")=="-3","case-insensitive unique constraint")
    check(call(1,"'RecordName'")=="-1","no-op does not consume cooldown")
    check(int(call(1,"'NextName'"))>=3590,"second change requires one hour")
    check(int(call(1,"NULL"))>=3590,"reset shares cooldown")
    check(call(2,"'^1Color'")=="-2","database rejects color codes")
    check(call(2,"'FixtureToken'")=="-5","database rechecks private moderation")
    check(call(2,"'1234567890123456'")=="-2","database enforces visible name length")
    check(db("SELECT normalizeModeratedName('^1F1x.tuure Token');",database)=="fixturetoken","normalization semantics")
    check(db("SELECT blockedNameRule('xF1x.tuureTokenx')>0,blockedNameRule('OkFixtureToken');",database)=="1\t0","obfuscation and exception")
    db("UPDATE playerNamePreferences SET changedAt=UTC_TIMESTAMP(6)-INTERVAL 3600 SECOND WHERE playerID=1;",database)
    check(call(1,"'NextName'")=="0","one-hour boundary allows change")
    check(call(2,"'RecordName'")=="0","released preferred name becomes available")
    check(db("SELECT resetPreferredNameByModerator(1,2);",database)=="-6","ordinary account cannot moderate")
    check(db("SELECT resetPreferredNameByModerator(3,2);",database)=="0","moderator reset succeeds")
    check(int(call(2,"'Immediate'"))>=3590,"moderator reset starts cooldown")
    with ThreadPoolExecutor(max_workers=2) as pool:
        results=list(pool.map(lambda pid:call(pid,"'RaceHandle'"),[4,5]))
    check(sorted(results)==["-3","0"],"concurrent claim has exactly one winner")
    check(db("SELECT COUNT(*) FROM playerNamePreferences WHERE preferredName='RaceHandle';",database)=="1","unique name survives concurrent requests")
    # Reset only disposable fixture state for the engine-side command tests.
    db("DELETE FROM playerNamePreferences;",database)
    for folder in ("opencj","maps"):shutil.copytree(ROOT/"server-gsc"/folder,mod/folder)
    for asset in ("mod.ff","z_opencj.iwd"):(mod/asset).symlink_to("/mod-assets/"+asset)
    (home/"plugins").mkdir()
    (home/"steamclient.so").symlink_to("/game/steamclient.so")
    shutil.copyfile(ROOT/"dev-tools/tests/player-names.gsc",mod/"opencj/names103test.gsc")
    (mod/"maps/mp/gametypes/cj.gsc").write_text('main() { level.script=getCvar("mapname"); }\n')
    (mod/"maps/mp/gametypes/_callbacksetup.gsc").write_text(
        'CodeCallback_StartGameType() { thread openCJ\\names103Test::main(); }\n'+
        "\n".join("CodeCallback_"+x+"() {}" for x in ["PlayerConnect","PlayerDisconnect","PlayerDamage","PlayerKilled","PlayerLastStand","UserInfoChanged","MovementState"]))
    (mod/"maps/mp/mp_killhouse.gsc").write_text("main() {}\n")
    cfg=(ROOT/"dev-tools/local/runtime/mods/opencj/opencj-dev.cfg").read_text()
    lines=[line for line in cfg.splitlines() if re.match(r"\s*set(?:a)?\s+db_",line)]
    for line in lines:
        match=re.match(r'\s*set(?:a)?\s+db_pass\s+"([^"]*)"',line)
        if match:secrets.append(match[1])
    lines=[re.sub(r"(db_base\s+).*",lambda m:m[1]+'"'+database[:-1]+'"',line) for line in lines]
    private=mod/"names103.cfg";private.write_text("\n".join(lines)+"\n");private.chmod(0o600)
    args=["docker","compose","run","-d","--no-deps","--name",container,"server","/workspace/cod4x-server/bin/cod4x18_dedrun"]
    for k,v in [("fs_basepath","/game"),("fs_homepath","/workspace/dev-tools/local/"+tag),("fs_game","mods/opencj"),("dedicated","2"),("net_port","28973"),("sv_maxclients","2"),("sv_authorizemode","0"),("com_hunkMegs","1024"),("developer","1"),("g_gametype","cj")]:args+=["+set",k,v]
    args+=["+exec","names103.cfg","+map","mp_killhouse"]
    subprocess.run(args,cwd=ROOT/"dev-tools",check=True,capture_output=True);started=True
    for _ in range(40):
        time.sleep(1)
        p=subprocess.run(["docker","logs",container],capture_output=True,text=True);log=redact(p.stdout+p.stderr)
        if any(x in log for x in ("NAME SELFTEST COMPLETE","script compile error","script runtime error")):break
    (home/"console.log").write_text(log)
    for line in log.splitlines():
        if "NAME SELFTEST" in line:print(line,flush=True)
    error=re.search(r"script (?:compile|runtime) error",log)
    if error:print(log[error.start():error.start()+1200],flush=True)
    assert "NAME SELFTEST COMPLETE failures=0" in log and not error,home
    assert report["failures"]==0,report
    report["engineSummary"]=next(l for l in log.splitlines() if "NAME SELFTEST COMPLETE" in l)
    report["nativeSha256"]=hashlib.sha256((ROOT/"cod4x-server/bin/cod4x18_dedrun").read_bytes()).hexdigest()
    (home/"result.json").write_text(json.dumps(report,indent=2)+"\n")
finally:
    if started:subprocess.run(["docker","rm","-f",container],capture_output=True)
    if granted:db("REVOKE ALL PRIVILEGES ON "+database+".* FROM 'opencj'@'%';")
    if created:db("DROP DATABASE "+database+";")
    for secret in (mod/"names103.cfg",):
        if secret.exists():secret.unlink()
    print("Evidence:",home,flush=True)
