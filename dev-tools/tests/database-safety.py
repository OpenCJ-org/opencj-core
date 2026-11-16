"""Rehearse database safety on a full disposable backup copy; never write live DB."""
from compose_environment import database_network
from pathlib import Path
import concurrent.futures, gzip, hashlib, importlib.util, json, re, secrets, shutil, subprocess, sys, time, uuid
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/"server-db/tools"))
from mysql_session import MySQL
import migrate, runtime_access
tag="database-safety-"+uuid.uuid4().hex[:8]
home=ROOT/"dev-tools/local"/tag;home.mkdir(mode=0o700)
name="opencj-"+tag;database="route_fixture_cod4"
password=secrets.token_hex(24);private=home/"mysql.env"
private.write_text("MYSQL_ROOT_PASSWORD="+password+"\nMYSQL_DATABASE=route_fixture_cod4\nMYSQL_USER=opencj\nMYSQL_PASSWORD="+password+"\n");private.chmod(0o600)
report={"liveDatabaseWrites":False,"checks":[]};started=False
def run(args,**kw):return subprocess.run(args,capture_output=True,text=True,**kw)
def check(ok,label):
    if not ok:raise AssertionError(label)
    report["checks"].append(label);print("SAFE PASS "+label,flush=True)
def expect_failure(sql,runtime=False):
    try:
        with MySQL(name,database,runtime=runtime) as c:c.query(sql)
    except RuntimeError as error:
        return str(error)
    raise AssertionError("Expected SQL rejection: "+sql[:120])
def checksum(c,query):
    return hashlib.sha256("\n".join(sorted(c.query(query).splitlines())).encode()).hexdigest()
try:
    network=database_network()
    p=run(["docker","run","-d","--name",name,"--network",network,"--memory","1536m","--env-file",str(private),"mysql:8.0","--log-bin-trust-function-creators=1"])
    assert not p.returncode;started=True
    for _ in range(90):
        p=run(["docker","exec",name,"sh","-c",'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql --protocol=TCP -h127.0.0.1 -N -u root -e "SELECT 1"'])
        if not p.returncode:break
        time.sleep(1)
    else:raise RuntimeError("Fixture did not start")
    source=Path(sys.argv[1])
    raw=gzip.decompress(source.read_bytes()).decode()
    raw=raw.replace(chr(96)+"openCJ_cod4"+chr(96),chr(96)+database+chr(96))
    with MySQL(name,database) as db:
        db.query(raw,timeout=240)
        db.query("USE "+database+";")
        db.query("GRANT ALL ON opencj_test_cod4.* TO 'opencj'@'%';")
        del raw
        legacy_hash=checksum(db,"SELECT * FROM opencj_test_cod4.playerRuns;")
        db.query("""
INSERT INTO mapids(mapID,mapname) VALUES(800001,'safety_fixture_a'),(800002,'safety_fixture_b');
INSERT INTO playerInformation(playerID,playerName) VALUES(800401,'Safety Fixture A'),(800402,'Safety Fixture B');
INSERT INTO checkpoints(cpID,mapID,x,y,z,radius,onGround,allowSave,elevate) VALUES
(800101,800001,0,0,0,64,1,1,0),(800102,800002,0,0,0,64,1,1,0),(800103,800001,0,0,0,64,1,1,0);
INSERT INTO routes(routeID,mapID,cpID,routeName) VALUES(800201,800001,800101,'safety_a'),(800202,800002,800102,'safety_b');
INSERT INTO playerRuns(runID,playerID,mapID,instanceNumber,FPSMode,hb) VALUES(800301,800401,800001,1,'mix',0),(800302,800402,800002,1,'mix',0);
SELECT checkpointPassed(800301,800101,1000,1,2,3,4,5,'mix',0,0,0,1);
SELECT checkpointPassed(800301,800101,2000,6,7,8,9,10,'125',1,1,1,1);
""")
        check(db.query("SELECT timePlayed,explosiveJumps FROM checkpointStatistics WHERE runID=800301;")=="2000\t3","reproduced old checkpoint bug: new time retained old RPG count")
        db.query("DELETE FROM checkpointStatistics WHERE runID=800301;")
        tables=db.query("SELECT table_name FROM information_schema.tables WHERE table_schema=DATABASE() AND table_type='BASE TABLE' ORDER BY table_name;").splitlines()
        queries={}
        for table in tables:
            columns=[line.split("\t")[0] for line in db.query("SHOW COLUMNS FROM "+table+";").splitlines()]
            queries[table]="SELECT "+",".join(chr(96)+c+chr(96) for c in columns)+" FROM "+table+";"
        before={t:checksum(db,q) for t,q in queries.items()}
        migrations=migrate.files()
        migrate.lock(db,database)
        try:migrate.apply(db,migrations)
        except RuntimeError:pass
        else:raise AssertionError("Untracked DB should refuse apply")
        check(True,"untracked databases cannot automatically replay migrations")
        migrate.adopt020(db,migrations)
        with MySQL(name,database) as other:
            try:migrate.lock(other,database)
            except RuntimeError:pass
            else:raise AssertionError("Second migration lock should fail")
        check(True,"concurrent migration runner rejected")
        check(migrate.apply(db,migrations)==[21,22,23],"all new migrations applied through tracked runner")
        check(all(checksum(db,q)==before[t] for t,q in queries.items()),"all existing gameplay rows and payloads preserved")
        check(migrate.apply(db,migrations)==[],"re-running migration tool is a no-op")
        changed=dict(migrations);old=changed[15];changed[15]=(old[0],"0"*64,old[2])
        try:migrate.validate(migrate.ledger(db),changed)
        except RuntimeError:pass
        else:raise AssertionError("Checksum mismatch not rejected")
        check(True,"modified historical migration rejected")
        db.query("UPDATE schemaMigrations SET state='applying' WHERE version=23;")
        try:migrate.apply(db,migrations)
        except RuntimeError:pass
        else:raise AssertionError("Interrupted migration not rejected")
        db.query("UPDATE schemaMigrations SET state='applied' WHERE version=23;")
        check(True,"interrupted migration cannot silently rerun")
        db.query("SELECT RELEASE_LOCK('opencj:migrate:"+database+"');")
        db.query("SELECT checkpointPassed(800301,800101,1000,1,2,3,4,5,'mix',0,0,0,1); SELECT checkpointPassed(800301,800101,2000,6,7,8,9,10,'125',1,1,1,1);")
        expected="2000\t6\t7\t8\t9\t10\t125\t1\t1\t1"
        projection="SELECT timePlayed,saveCount,loadCount,explosiveJumps,explosiveLaunches,doubleExplosives,FPSMode,ele,anyPct,hardTAS FROM checkpointStatistics WHERE runID=800301;"
        check(db.query(projection)==expected,"later checkpoint pass updates every statistic consistently")
        db.query("SELECT checkpointPassed(800301,800101,1500,0,0,0,0,0,'mix',0,0,0,1); SELECT checkpointPassed(800301,800101,2000,0,0,0,0,0,'mix',0,0,0,1);")
        check(db.query(projection)==expected,"older and equal-time checkpoint writes leave accepted statistics unchanged")
        check(db.query("SELECT checkpointPassed(800301,800101,3000,0,0,0,0,0,'mix',0,0,0,99);")=="NULL","stale run owner cannot overwrite checkpoint statistics")
        db.query("INSERT INTO playerSaves(runID,saveNumber,x,y,z,alpha,beta,gamma,explosiveJumps,doubleExplosives,checkpointID,flags) VALUES(800301,0,0,0,0,0,0,0,0,0,800101,0);")
        for label,query in [
            ("checkpoint with history","DELETE FROM checkpoints WHERE cpID=800101;"),
            ("run with history","DELETE FROM playerRuns WHERE runID=800301;"),
            ("player with runs","DELETE FROM playerInformation WHERE playerID=800401;"),
            ("map with checkpoints/runs","DELETE FROM mapids WHERE mapID=800001;"),
            ("missing saved checkpoint","UPDATE playerSaves SET checkpointID=99999999 WHERE runID=800301;"),
            ("save on another map","UPDATE playerSaves SET checkpointID=800102 WHERE runID=800301;"),
            ("finish on another map","UPDATE playerRuns SET finishcpID=800102 WHERE runID=800301;"),
            ("moving checkpoint to another map","UPDATE checkpoints SET mapID=800002 WHERE cpID=800101;"),
            ("moving run to another map","UPDATE playerRuns SET mapID=800002 WHERE runID=800301;"),
            ("moving route to another map","UPDATE routes SET mapID=800002 WHERE routeID=800201;"),
            ("cross-map connection","INSERT INTO checkpointConnections VALUES(800101,800102);"),
            ("cross-map alternatives","INSERT INTO checkpointBrothers VALUES(800101,800102);"),
            ("cross-map route membership","INSERT INTO checkpointRoutes VALUES(800101,800202);"),
            ("self connection","INSERT INTO checkpointConnections VALUES(800101,800101);"),
            ("self alternative","INSERT INTO checkpointBrothers VALUES(800101,800101);"),
            ("cross-map checkpoint statistics","SELECT checkpointPassed(800302,800101,123,0,0,0,0,0,'mix',0,0,0,1);"),
        ]:
            expect_failure(query);check(True,"reject "+label)
        db.query("INSERT INTO checkpointConnections VALUES(800101,800103);")
        expect_failure("INSERT INTO checkpointConnections VALUES(800101,800103);")
        check(True,"duplicate checkpoint connections rejected")
        db.query("UPDATE checkpoints SET retired=1 WHERE cpID=800101; UPDATE playerRuns SET archived=1 WHERE runID=800301; UPDATE routes SET routeName='renamed_safety' WHERE routeID=800201;")
        check(db.query("SELECT COUNT(*) FROM playerSaves WHERE runID=800301;")=="1","retirement, archive and route rename preserve saves")
        db.query("INSERT INTO challenges(challengeKey,tier,points,mapID,routeLabel) VALUES('safety.reward',1,100,800001,'Safety'); INSERT INTO challengeCompletions(playerID,challengeKey,runID,pointsAwarded) VALUES(800401,'safety.reward',800301,100); INSERT INTO shopCatalog(itemKey,category,slot,price,available) VALUES('safety.item',1,'safety-slot',30,1),('safety.other',1,'safety-other',60,1);")
        expect_failure("INSERT INTO challengeCompletions(playerID,challengeKey,runID,pointsAwarded) VALUES(800402,'safety.reward',800301,100);")
        check(True,"challenge award cannot refer to another player's run")
        check(db.query("CALL shopBuyOrEquip(800401,'safety.item',0,30);")=="ok","purchase spends earned award points")
        db.query("UPDATE challenges SET points=1,active=0 WHERE challengeKey='safety.reward';")
        check(db.query("SELECT SUM(pointsAwarded)-(SELECT SUM(pointsSpent) FROM shopPurchases WHERE playerID=800401) FROM challengeCompletions WHERE playerID=800401;")=="70","reward edits and retirement preserve earned spending balance")
        check(db.query("CALL shopBuyOrEquip(800401,'safety.other',0,60);")=="ok","retired challenge reward remains spendable")
        db.query("INSERT INTO shopCatalog(itemKey,category,slot,price,available) VALUES('safety.third',1,'safety-third',11,1);")
        check(db.query("CALL shopBuyOrEquip(800401,'safety.third',0,11);")=="balance","historical spending still prevents overspending")
        expect_failure("DELETE FROM challenges WHERE challengeKey='safety.reward';")
        expect_failure("DELETE FROM shopCatalog WHERE itemKey='safety.item';")
        check(True,"awarded challenges and purchased items cannot be accidentally deleted")
        runtime_access.apply_policy(db,database,readonly_database="opencj_test_cod4")
        runtime_access.apply_policy(db,database,readonly_database="opencj_test_cod4")
        check(True,"runtime permissions can be reapplied consistently")
        for label,query in [
            ("drop table","DROP TABLE playerRuns;"),("alter schema","ALTER TABLE playerRuns ADD unsafe INT;"),
            ("create table","CREATE TABLE unsafe(id INT);"),("delete saved progress","DELETE FROM playerSaves WHERE runID=800301;"),
            ("delete runs","DELETE FROM playerRuns WHERE runID=800301;"),("delete accounts","DELETE FROM playerInformation WHERE playerID=800401;"),
            ("delete checkpoints","DELETE FROM checkpoints WHERE cpID=800101;"),("rewrite migration ledger","UPDATE schemaMigrations SET sha256='bad';"),
            ("change old award amounts","UPDATE challengeCompletions SET pointsAwarded=999;"),
            ("delete old test data","DELETE FROM opencj_test_cod4.playerRuns;"),
        ]:
            expect_failure(query,runtime=True);check(True,"runtime account cannot "+label)
        with MySQL(name,database,runtime=True) as runtime:
            check(runtime.query("SELECT checkpointPassed(800301,800103,4000,1,2,3,4,5,'mix',0,0,0,1);")=="1","runtime account can record checkpoint progress")
            check(runtime.query("SELECT saveRun(800301,1,'Safety run');")=="800301","runtime account can name a run")
            check(runtime.query("CALL shopBuyOrEquip(800401,'safety.item',1,30);")=="ok","runtime account can equip a purchased item")
            runtime.query("DELETE FROM checkpointConnections WHERE cpID=800101 AND childcpID=800103;")
            runtime.query("INSERT INTO demoClipSessions(sessionID) VALUES('safety-session'); DELETE FROM demoClipSessions WHERE sessionID='safety-session';")
            check(True,"layout rebuilding and temporary clip cleanup remain permitted")
            check(runtime.query("SELECT COUNT(*) FROM playerDisplayNames;")!="0","runtime account can read preferred-name view")
            new_player=runtime.query("SELECT createNewAccount(987654,123456,456789,987123,'Safety New');")
            check(new_player not in ("NULL","0",""),"runtime account can create new players through its procedure")
            check(runtime.query("SELECT createNewAccount(987654,123456,456789,987123,'Safety Duplicate');")=="NULL","duplicate account cleanup still works inside privileged routine")
        check(checksum(db,"SELECT * FROM opencj_test_cod4.playerRuns;")==legacy_hash,"legacy test database gameplay rows untouched")
        spec=importlib.util.spec_from_file_location("record72",ROOT/"dev-tools/tests/record-notices-72.py")
        record72=importlib.util.module_from_spec(spec);spec.loader.exec_module(record72)
        check(record72.verify(db.query)==36,"all 36 record category comparisons still pass")
        report["passed"]=True
        report["fixtureContainer"]=name
        # Retain this isolated DB for the subsequent real-engine regression.
        (home/"fixture.json").write_text(json.dumps({"container":name,"database":database,"private":str(private)}))
        print("SAFE_FIXTURE "+str(home),flush=True)
finally:
    if not report.get("passed") and started:
        report["databaseRemoved"]=run(["docker","rm","-f","-v",name]).returncode==0
        private.unlink(missing_ok=True)
    (home/"result.json").write_text(json.dumps(report,indent=2)+"\n")
    print("SAFE_RESULT "+str(home/"result.json"),flush=True)
