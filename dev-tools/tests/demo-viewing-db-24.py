"""Rehearse #24 migration and concurrent view counting in a disposable database."""
from pathlib import Path
import concurrent.futures,json,secrets,subprocess,sys,time,uuid
root=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(root/"server-db/tools"))
from mysql_session import MySQL
tag="demo-viewing-db-24-"+uuid.uuid4().hex[:8]
home=root/"dev-tools/local"/tag;home.mkdir(mode=0o700)
name="opencj-"+tag;database="viewing_fixture"
private=home/"mysql.env";secret=secrets.token_hex(24)
private.write_text("MYSQL_ROOT_PASSWORD="+secret+"\nMYSQL_DATABASE="+database+"\nMYSQL_USER=opencj\nMYSQL_PASSWORD="+secret+"\n");private.chmod(0o600)
checks=[]
def run(args):return subprocess.run(args,capture_output=True,text=True,check=True)
def check(ok,label):
    assert ok,label
    checks.append(label);print("VIEWING DB PASS "+label,flush=True)
try:
    run(["docker","run","-d","--name",name,"--network","none","--memory","1024m","--env-file",str(private),"mysql:8.0"])
    for i in range(90):
        try:
            with MySQL(name,database) as db:db.query("SELECT 1;")
            break
        except RuntimeError:time.sleep(1)
    else:raise RuntimeError("Fixture did not start")
    with MySQL("opencj-dev-db-1","openCJ_cod4") as live:
        schemas=[live.query("SHOW CREATE TABLE "+table+";").split("\t",1)[1]+";" for table in ["demoClipSessions","demoClips"]]
    with MySQL(name,database) as db:
        db.query("CREATE TABLE mapids(mapID INT PRIMARY KEY); CREATE TABLE playerInformation(playerID INT PRIMARY KEY);")
        for sql in schemas:db.query(sql)
        db.query("""INSERT INTO mapids VALUES(1);
INSERT INTO playerInformation VALUES(1),(2),(3);
INSERT INTO demoClipSessions(sessionID) VALUES('session-a'),('session-b');
INSERT INTO demoClips(clipID,uploadToken,mapID,playerID,description,scopeKey,sessionID,slot,originX,originY,originZ,frameCount)
VALUES(1,'upload-a',1,1,'Original clip','permanent',NULL,1,0,0,0,20),
(2,'upload-b',1,1,'Unpublished','permanent',NULL,2,0,0,0,20);
UPDATE demoClips SET ready=1 WHERE clipID=1;""")
        before=db.query("SELECT clipID,uploadToken,description,frameCount,ready FROM demoClips ORDER BY clipID;")
        db.query((root/"server-db/migrations/024-demo-viewing.sql").read_text())
        check(db.query("SELECT clipID,uploadToken,description,frameCount,ready FROM demoClips ORDER BY clipID;")==before,"migration preserves existing clip rows")
        check(db.query("SELECT RPGShots,FPSMode,eleUsed,viewCount FROM demoClips WHERE clipID=1;")=="NULL\tNULL\tNULL\t0","legacy metadata is explicitly unknown")
        db.query("REVOKE ALL PRIVILEGES, GRANT OPTION FROM 'opencj'@'%';")
        db.query("GRANT SELECT ON viewing_fixture.* TO 'opencj'@'%'; GRANT EXECUTE ON PROCEDURE viewing_fixture.countClipView TO 'opencj'@'%';")
    def view(viewer=2,clip=1,session="session-a"):
        with MySQL(name,database,runtime=True) as db:db.query("CALL countClipView('"+session+"',"+str(clip)+","+str(viewer)+");")
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:list(pool.map(lambda _:view(),range(32)))
    with MySQL(name,database) as db:
        check(db.query("SELECT viewCount FROM demoClips WHERE clipID=1;")=="1","32 simultaneous duplicate calls count once")
    view(1);view(2,2);view(2,999);view(2,1,"missing")
    with MySQL(name,database) as db:
        check(db.query("SELECT viewCount FROM demoClips WHERE clipID=1;")=="1","owner, unpublished, missing clip and missing session do not count")
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:list(pool.map(lambda i:view(2+i%2),range(32)))
    view(2,1,"session-b")
    with MySQL(name,database) as db:
        check(db.query("SELECT viewCount FROM demoClips WHERE clipID=1;")=="3","different viewer and new server session each count")
        check(db.query("SELECT COUNT(*) FROM demoClipViews;")=="3","one receipt per accepted view")
        db.query("DELETE FROM demoClipSessions WHERE sessionID='session-a';")
        check(db.query("SELECT COUNT(*) FROM demoClipViews;")=="1" and db.query("SELECT viewCount FROM demoClips WHERE clipID=1;")=="3","session expiry removes receipts and retains total views")
        db.query("DELETE FROM demoClips WHERE clipID=1;")
        check(db.query("SELECT COUNT(*) FROM demoClipViews;")=="0","clip deletion removes its receipts")
    (home/"result.json").write_text(json.dumps({"liveDatabaseWrites":False,"checks":checks},indent=2)+"\n")
    print("VIEWING DB COMPLETE checks="+str(len(checks))+" failures=0\nEvidence: "+str(home),flush=True)
finally:
    subprocess.run(["docker","rm","-f",name],capture_output=True)
    private.unlink(missing_ok=True)
