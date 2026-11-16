"""Separate database cleanup: migrate and exercise a disposable copy only."""
from pathlib import Path
import subprocess,re,json,secrets,uuid,time,hashlib,shutil,sys,importlib.util,gzip
ROOT=Path(__file__).resolve().parents[2]
tag="database-cleanup-"+uuid.uuid4().hex[:8]
home=ROOT/"dev-tools/local"/tag;home.mkdir(parents=True);home.chmod(0o700)
name="opencj-"+tag;database="route_fixture_cod4"
password=secrets.token_hex(24);private=home/"mysql.env"
private.write_text("MYSQL_ROOT_PASSWORD="+password+"\n");private.chmod(0o600)
report={"liveDatabaseWrites":False};created=False;engineStarted=False;engine=name+"-engine"
def run(args,**kw):return subprocess.run(args,text=True,capture_output=True,**kw)
def db(query,source=False,fail=False):
 target="opencj-dev-db-1" if source else name
 p=run(["docker","exec","-i",target,"sh","-c",'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql --binary-as-hex -N -u root'],input=query,timeout=120)
 if fail:
  assert p.returncode,"Expected SQL constraint failure"
  return
 if p.returncode:
  (home/"sql-error.txt").write_text(p.stderr.replace(password,"<redacted>"))
  raise RuntimeError("SQL failed: "+p.stderr[:500].replace(password,"<redacted>"))
 return p.stdout.strip()
def sql(query,**kw):return db("USE "+database+";\n"+query,**kw)
def check(value,label):
 assert value,label
 report.setdefault("checks",[]).append(label)
 print("DBC PASS "+label,flush=True)
def rows(query):return sql(query).splitlines()
def checksum(query):return hashlib.sha256("\n".join(sorted(sql(query).splitlines())).encode()).hexdigest()
try:
 network=run(["docker","inspect","-f","{{range $key, $value := .NetworkSettings.Networks}}{{$key}}{{end}}","opencj-dev-db-1"]).stdout.strip()
 assert re.fullmatch(r"opencj[-\w]+",network)
 p=run(["docker","run","-d","--name",name,"--network",network,"--memory","1536m","--env-file",str(private),"mysql:8.0","--log-bin-trust-function-creators=1"])
 assert p.returncode==0;created=True
 for _ in range(90):
  p=run(["docker","exec",name,"sh","-c",'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql --protocol=TCP -h127.0.0.1 -N -u root -e "SELECT 1"'])
  if not p.returncode:break
  time.sleep(1)
 else:raise RuntimeError("Fixture DB startup failed")
 if "--legacy-dump" in sys.argv:
  legacy=Path(sys.argv[sys.argv.index("--legacy-dump")+1]).resolve()
  raw=gzip.decompress(legacy.read_bytes()).decode() if legacy.suffix==".gz" else legacy.read_text()
 else:
  if db("SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='openCJ_cod4' AND table_name='challenges' AND column_name='mapName';",source=True)!="1":
   raise RuntimeError("Live schema already migrated; pass --legacy-dump <pre-020 SQL or SQL.gz backup>")
  dump=run(["docker","exec","opencj-dev-db-1","sh","-c",'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump -u root --single-transaction --hex-blob --routines --triggers --skip-comments --no-tablespaces --set-gtid-purged=OFF --column-statistics=0 openCJ_cod4'])
  assert not dump.returncode
  raw=dump.stdout
 schema=re.sub(r"DEFINER=\S+\s","DEFINER=CURRENT_USER ",raw.replace("openCJ_cod4",database))
 db("CREATE DATABASE "+database+" CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;")
 sql(schema);del schema,raw

 # Exercise safe refusal before cleanup DDL, using transaction-only fixtures.
 migration=(ROOT/"server-db/migrations/020-database-cleanup.sql").read_text()
 report["migrationSha256"]=hashlib.sha256(migration.encode()).hexdigest()
 sql(migration.split("CALL preflightCleanup020();",1)[0])
 sql("START TRANSACTION;INSERT INTO demoEvents(eventID) VALUES(-999174);CALL preflightCleanup020();",fail=True)
 check(sql("SELECT COUNT(*) FROM demoEvents")=="0","nonempty legacy tables stop cleanup without discarding data")
 rid=sql("SELECT MIN(runID) FROM playerRuns")
 sql("START TRANSACTION;UPDATE playerRuns SET runLabel='old fixture' WHERE runID="+rid+";INSERT INTO runLabels VALUES("+rid+",'new fixture');CALL preflightCleanup020();",fail=True)
 check(True,"conflicting run labels stop cleanup instead of choosing one")
 sql("START TRANSACTION;UPDATE routes SET routeShaderColor='blue' LIMIT 1;CALL preflightCleanup020();",fail=True)
 check(True,"populated legacy colors stop cleanup instead of losing color")
 sql("DROP PROCEDURE preflightCleanup020;")
 sql("UPDATE playerRuns SET runLabel='Recovered fixture label' WHERE runID="+rid)
 player=sql("SELECT MIN(playerID) FROM playerInformation")
 sql("INSERT INTO shopCatalog(itemKey,category,slot,price,available) VALUES('cleanup.fixture',1,'cleanup-slot',0,1);")
 check(sql("CALL shopBuyOrEquip("+player+",'cleanup.fixture',0,0)")=="ok","pre-migration equipment and purchase fixture created")
 immutable=["playerRuns","checkpointStatistics","playerSaves","demoRuns","demoWinners","demoChunks","demoClipChunks","demoClips","demoClipSessions","challengeCompletions","checkpointConnections","checkpointBrothers","checkpointRoutes","shopPurchases","shopCatalog","checkpointAreas","checkpoints","routes"]
 projections={}
 for table in immutable:
  cols=[l.split("\t")[0] for l in rows("SHOW COLUMNS FROM "+table)]
  removed={"playerRuns":{"runLabel"},"checkpoints":{"endShaderColor"},"routes":{"routeShaderColor"}}.get(table,set())
  projections[table]="SELECT "+",".join(chr(96)+c+chr(96) for c in cols if c not in removed)+" FROM "+table+" ORDER BY 1,2"
 before={t:checksum(q) for t,q in projections.items()}
 catalogue=rows("SELECT mapID,mapname,releaseDate,inRotation FROM mapids ORDER BY mapID")
 challenges=rows("SELECT challengeKey,mapName,routeID,routeHint,routeLabel FROM challenges ORDER BY challengeKey")
 mapCount=int(sql("SELECT COUNT(*) FROM mapids"))
 sql(migration)
 changed=[t for t,h in before.items() if checksum(projections[t])!=h]
 check(not changed,"all gameplay/history/demo/shop data unchanged"+(" (changed: "+str(changed)+")" if changed else ""))
 check(sql("SELECT runLabel FROM runLabels WHERE runID="+rid)=="Recovered fixture label","legacy run label retained in the canonical table")
 runIdentity=checksum("SELECT * FROM playerRuns WHERE runID="+rid)
 instance=sql("SELECT instanceNumber FROM playerRuns WHERE runID="+rid)
 check(sql("SELECT saveRun("+rid+","+instance+",'Player chosen label')")==rid,"player can rename an existing run using its runID")
 check(sql("SELECT runLabel FROM runLabels WHERE runID="+rid)=="Player chosen label","new player label is stored in the canonical table")
 check(checksum("SELECT * FROM playerRuns WHERE runID="+rid)==runIdentity,"renaming does not modify run identity or history")
 otherRun=sql("SELECT MIN(runID) FROM playerRuns WHERE runID<>"+rid)
 otherInstance=sql("SELECT instanceNumber FROM playerRuns WHERE runID="+otherRun)
 sql("SELECT saveRun("+otherRun+","+otherInstance+",'Player chosen label')")
 check(sql("SELECT COUNT(*) FROM runLabels WHERE runLabel='Player chosen label'")=="2","same display label can identify two separate runIDs")
 check(challenges==rows("SELECT c.challengeKey,m.mapname,c.routeID,c.routeHint,c.routeLabel FROM challenges c JOIN mapids m USING(mapID) ORDER BY c.challengeKey"),"every challenge retains its map, route and labels")
 check(catalogue==rows("SELECT mapID,mapname,releaseDate,inRotation FROM mapids WHERE mapID IN ("+",".join(l.split("\t")[0] for l in catalogue)+") ORDER BY mapID"),"existing map metadata and voting pool unchanged")
 newMaps=int(sql("SELECT COUNT(*) FROM mapids"))-mapCount;report["newMapIdentities"]=newMaps
 check(newMaps==11,"eleven previously unregistered challenge maps receive IDs")
 check(sql("SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='"+database+"' AND ((table_name='playerRuns' AND column_name='runLabel') OR (table_name='challenges' AND column_name='mapName') OR (table_name='shopEquipped' AND column_name='category') OR (table_name='checkpoints' AND column_name='endShaderColor') OR (table_name='routes' AND column_name='routeShaderColor'))")=="0","obsolete duplicate fields removed")
 check(sql("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='"+database+"' AND table_name IN ('playerSaves_test','playerRecordings','demoEvents')")=="0","three unused empty tables removed")
 check(sql("SELECT COUNT(*) FROM information_schema.routines WHERE routine_schema='"+database+"' AND routine_name IN ('createEvent','prepareAllDemos','prepareDemo','savePosition_test','storeDemoFrame')")=="0","five obsolete functions removed")
 sql("INSERT INTO mapids(mapname) VALUES('cleanup_constraint_map')")
 otherMap=sql("SELECT mapID FROM mapids WHERE mapname='cleanup_constraint_map'")
 cp=sql("SELECT MIN(cpID) FROM checkpointAreas")
 sql("UPDATE checkpointAreas SET mapID="+otherMap+" WHERE cpID="+cp,fail=True)
 check(True,"area cannot disagree with its checkpoint map")
 key=sql("SELECT challengeKey FROM challenges WHERE routeID IS NOT NULL LIMIT 1")
 sql("UPDATE challenges SET mapID="+otherMap+" WHERE challengeKey='"+key+"'",fail=True)
 check(True,"challenge cannot link to a route on another map")
 winnerRun=sql("SELECT runID FROM demoWinners LIMIT 1")
 sql("UPDATE demoWinners SET modeMask=16 WHERE runID="+winnerRun,fail=True)
 check(True,"winner cannot disagree with its demo category")
 sql("UPDATE shopEquipped SET slot='wrong-slot' WHERE itemKey='cleanup.fixture'",fail=True)
 check(True,"equipped item cannot disagree with its catalogue slot")
 sql("UPDATE shopCatalog SET slot='cleanup-new-slot',price=75 WHERE itemKey='cleanup.fixture'")
 check(sql("SELECT slot FROM shopEquipped WHERE itemKey='cleanup.fixture'")=="cleanup-new-slot","equipment follows catalogue slot changes atomically")
 check(sql("SELECT pointsSpent FROM shopPurchases WHERE itemKey='cleanup.fixture'")=="0","historical purchase price survives catalogue price change")
 check(sql("CALL shopBuyOrEquip("+player+",'cleanup.fixture',1,75)")=="ok","owned item still equips after cleanup")
 renamedMap=sql("SELECT mapID FROM challenges WHERE challengeKey='dark.hard'")
 sql("UPDATE mapids SET mapname='cleanup_renamed_dark' WHERE mapID="+renamedMap)
 sql("SELECT c.challengeKey,m.mapname,COALESCE(rt.routeName,c.routeLabel),c.points,c.maxTimeMs,c.maxRPG,c.routeID,COUNT(a.playerID),MAX(a.playerID="+player+"),c.fpsModes,c.allowedModes FROM challenges c JOIN mapids m ON m.mapID=c.mapID LEFT JOIN routes rt ON rt.routeID=c.routeID LEFT JOIN challengeCompletions a ON a.challengeKey=c.challengeKey WHERE c.active=1 AND c.tier=4 GROUP BY c.challengeKey ORDER BY c.challengeKey")
 check(True,"challenge menu query resolves canonical map and route names")
 spec=importlib.util.spec_from_file_location("record72",ROOT/"dev-tools/tests/record-notices-72.py")
 record72=importlib.util.module_from_spec(spec);spec.loader.exec_module(record72)
 report["recordCategoryChecks"]=record72.verify(sql)
 check(report["recordCategoryChecks"]==36,"all exact-mode record comparisons remain valid")
 for followup in ["021-history-protection.sql","022-checkpoint-statistics.sql","023-earned-rewards.sql"]:
  sql((ROOT/"server-db/migrations"/followup).read_text())
 # Full GSC compilation plus real CPC publishing/renaming, against this DB only.
 db("CREATE USER 'fixture'@'%' IDENTIFIED BY '"+password+"';GRANT ALL ON "+database+".* TO 'fixture'@'%';")
 mod=home/"mods/opencj";mod.mkdir(parents=True)
 for folder in ["opencj","maps"]:shutil.copytree(ROOT/"server-gsc"/folder,mod/folder)
 for asset in ["mod.ff","z_opencj.iwd"]:(mod/asset).symlink_to("/mod-assets/"+asset)
 (home/"usermaps").symlink_to("/game/usermaps")
 (home/"plugins").mkdir()
 (home/"steamclient.so").symlink_to("/game/steamclient.so")
 shutil.copyfile(ROOT/"dev-tools/tests/checkpoints.gsc",mod/"opencj/route174test.gsc")
 shutil.copyfile(ROOT/"dev-tools/tests/checkpoint-migration-db.gsc",mod/"opencj/route174migration.gsc")
 p=mod/"opencj/route174test.gsc";code=p.read_text().replace('    printf("CPC SELFTEST COMPLETE',r'    openCJ\route174Migration::main();'+'\n    printf("CPC SELFTEST COMPLETE');p.write_text(code)
 p=mod/"opencj/events/init.gsc";code=p.read_text().replace('    thread _everyFrame();','    setDvar("g_FFAPlayerCanBlock",1); // Avoid unrelated debug-engine owner assertion on stock-map brushes.\n'+r'    thread openCJ\route174Test::main();'+'\n    thread _everyFrame();');p.write_text(code)
 # Bots do not perform the client startup acknowledgement. Camera startup
 # waits are unrelated to CPC and can outlive the synthetic slot's reuse.
 p=mod/"opencj/camera.gsc";code=p.read_text().replace(r'    self openCJ\clientInit::waitUntilFinished();','    return; // No interactive client handshake in this fixture.');p.write_text(code)
 cfg=mod/"route174.cfg"
 cfg.write_text(f'set db_host "{name}"\nset db_user "fixture"\nset db_pass "{password}"\nset db_base "{database[:-1]}"\nset db_port "3306"\n');cfg.chmod(0o600)
 relative=str(home.relative_to(ROOT))
 command=["docker","compose","run","-d","--no-deps","--name",engine,"server","/workspace/cod4x-server/bin/cod4x18_dedrun"]
 for k,v in [("fs_basepath","/game"),("fs_homepath","/workspace/"+relative),("fs_game","mods/opencj"),("dedicated",2),("net_port",28978),("sv_maxclients",4),("sv_authorizemode",0),("com_hunkMegs",1024),("developer",1),("g_gametype","cj")]:command+=["+set",k,str(v)]
 command+=["+exec","route174.cfg","+map","mp_killhouse"]
 p=run(command,cwd=ROOT/"dev-tools");assert not p.returncode;engineStarted=True
 print("DBC isolated GSC engine started",flush=True)
 for _ in range(120):
  time.sleep(1);p=run(["docker","logs",engine]);log=(p.stdout+p.stderr).replace(password,"<redacted>")
  if any(x in log for x in ["CPC SELFTEST COMPLETE","script compile error","script runtime error","Received signal:"]):break
 (home/"console.log").write_text(log)
 matches=[l for l in log.splitlines() if "CPC SELFTEST COMPLETE" in l or "CPC SELFTEST FAIL" in l or "CPC TEST DETAIL" in l or "SQL ERROR" in l or "MIGRATION SELFTEST" in l]
 report["engineChecks"]=log.count("CPC SELFTEST PASS:")
 print("\n".join(matches),flush=True)
 if "CPC SELFTEST COMPLETE failures=0" not in log:
  for marker in ["script compile error","script runtime error","ASSERTION FAILED"]:
   if marker in log:print(log[max(0,log.index(marker)-100):log.index(marker)+1800],flush=True)
  raise RuntimeError("CPC integration failed; see "+str(home/"console.log"))
 check("MIGRATION SELFTEST COMPLETE failures=0" in log,"completed runs, retired checkpoints and old demo payloads survive layout edits")
 check(True,"real GSC CPC suite: publication, shared routes, rename, history and reload")

 check(sql("SELECT mapID FROM challenges WHERE challengeKey='dark.hard'")==renamedMap,"catalogue startup retains challenge map identity after rename")
 check(sql("SELECT COUNT(*) FROM mapids WHERE mapname='mp_dark'")=="0","catalogue startup does not recreate an obsolete map name")
 report["sourceHashes"]={str(p.relative_to(ROOT/"server-gsc")):hashlib.sha256(p.read_bytes()).hexdigest() for p in (ROOT/"server-gsc/opencj").rglob("*.gsc")}
 report["passed"]=True
finally:
 if engineStarted:report["engineRemoved"]=run(["docker","rm","-f",engine]).returncode==0
 (home/"mods/opencj/route174.cfg").unlink(missing_ok=True)
 if created:report["databaseRemoved"]=run(["docker","rm","-f","-v",name]).returncode==0
 private.unlink(missing_ok=True)
 (home/"result.json").write_text(json.dumps(report,indent=2)+"\n")
 print("DBC result "+str(home/"result.json"),flush=True)
