"""#174 migration/rename regression on a disposable copy; never writes the live DB."""
from pathlib import Path
import subprocess,re,json,secrets,uuid,time,hashlib,shutil,sys,importlib.util,gzip
ROOT=Path(__file__).resolve().parents[2]
tag="routes-174-"+uuid.uuid4().hex[:8]
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
 print("R174 PASS "+label,flush=True)
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
  if db("SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='openCJ_cod4' AND table_name='checkpoints' AND column_name='ender';",source=True)!="1":
   raise RuntimeError("Live schema already migrated; pass --legacy-dump <pre-019 SQL or SQL.gz backup>")
  dump=run(["docker","exec","opencj-dev-db-1","sh","-c",'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump -u root --single-transaction --hex-blob --routines --triggers --skip-comments --no-tablespaces --set-gtid-purged=OFF --column-statistics=0 openCJ_cod4'])
  assert not dump.returncode
  raw=dump.stdout
 schema=re.sub(r"DEFINER=\S+\s","DEFINER=CURRENT_USER ",raw.replace("openCJ_cod4",database))
 db("CREATE DATABASE "+database+" CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;")
 sql(schema);del schema,raw
 immutable=["playerRuns","checkpointStatistics","playerSaves","demoChunks","demoClipChunks","demoClipSessions","challengeCompletions","checkpointConnections","checkpointBrothers"]
 before={t:checksum("SELECT * FROM "+t+" ORDER BY 1,2") for t in immutable}
 checkpoints=checksum("SELECT cpID,x,y,z,radius,onGround,mapID,elevate,endShaderColor,allowSave,retired FROM checkpoints ORDER BY cpID")
 area=checksum("SELECT cpID,mapID,routeName,ordinal,vertices,allowDoubleRPG,sectionName,platformRef,heightAbove FROM checkpointAreas ORDER BY cpID")
 ends=rows("SELECT cpID,mapID,ender FROM checkpoints WHERE ender IS NOT NULL AND ender<>'' ORDER BY cpID")
 demos=rows("SELECT runID,mapID,routeName FROM demoRuns ORDER BY runID")
 winners=rows("SELECT mapID,routeName,FPSMode,modeMask,kind,runID FROM demoWinners ORDER BY 1,2,3,4,5")
 challenges=rows("SELECT challengeKey,mapName,routeName FROM challenges WHERE routeName IS NOT NULL ORDER BY challengeKey")
 migration=(ROOT/"server-db/migrations/019-route-identity.sql").read_text()
 report["migrationSha256"]=hashlib.sha256(migration.encode()).hexdigest()
 sql(migration)
 check(all(checksum("SELECT * FROM "+t+" ORDER BY 1,2")==sha for t,sha in before.items()),"all runs, records, saves, demo payloads, rewards and graph unchanged")
 check(checkpoints==checksum("SELECT cpID,x,y,z,radius,onGround,mapID,elevate,endShaderColor,allowSave,retired FROM checkpoints ORDER BY cpID"),"checkpoint IDs and geometry unchanged")
 check(area==checksum("SELECT cpID,mapID,draftName,ordinal,vertices,allowDoubleRPG,sectionName,platformRef,heightAbove FROM checkpointAreas ORDER BY cpID"),"published draft ownership and geometry unchanged")
 check(ends==rows("SELECT c.cpID,c.mapID,r.routeName FROM checkpoints c JOIN routes r ON r.routeID=c.finishRouteID ORDER BY c.cpID"),"every old finish resolves through stable ID")
 check(demos==rows("SELECT d.runID,d.mapID,r.routeName FROM demoRuns d JOIN routes r USING(routeID) ORDER BY d.runID"),"all demo routes preserved")
 check(winners==rows("SELECT d.mapID,r.routeName,d.FPSMode,d.modeMask,d.kind,d.runID FROM demoWinners d JOIN routes r USING(routeID) ORDER BY 1,2,3,4,5"),"all demo winner categories preserved")
 check(challenges==rows("SELECT c.challengeKey,c.mapName,r.routeName FROM challenges c JOIN routes r USING(routeID) ORDER BY c.challengeKey"),"all challenge bindings preserved")
 check(sql("SELECT COUNT(*) FROM checkpoints c WHERE retired=0 AND NOT EXISTS(SELECT 1 FROM checkpointRoutes cr WHERE cr.cpID=c.cpID)")=="0","every active checkpoint has route membership")
 report["counts"]=sql("SELECT (SELECT COUNT(*) FROM routes),(SELECT COUNT(*) FROM checkpointRoutes),(SELECT COUNT(*) FROM checkpoints WHERE retired=0),(SELECT COUNT(*) FROM (SELECT cpID FROM checkpointRoutes GROUP BY cpID HAVING COUNT(*)>1) shared)").split("\t")
 # Rebuilding twice is idempotent and preserves retained checkpoint membership.
 links=checksum("SELECT * FROM checkpointRoutes ORDER BY cpID,routeID")
 for m in rows("SELECT DISTINCT mapID FROM checkpoints"):
  sql("START TRANSACTION;CALL rebuildCheckpointRoutes("+m+");CALL rebuildCheckpointRoutes("+m+");COMMIT;")
 check(links==checksum("SELECT * FROM checkpointRoutes ORDER BY cpID,routeID"),"membership rebuild is idempotent")
 # Rename every catalog entry, then re-read via new DB connections (reload).
 references={t:checksum("SELECT * FROM "+t+" ORDER BY 1,2") for t in ["demoRuns","demoWinners","challenges","checkpointRoutes","checkpoints"]}
 originalRoutes=rows("SELECT routeID,HEX(routeName) FROM routes ORDER BY routeID")
 sql("UPDATE routes SET routeName=CONCAT('renamed_',routeID);")
 check(all(checksum("SELECT * FROM "+t+" ORDER BY 1,2")==h for t,h in references.items()),"rename never rewrites linked history or challenge bindings")
 for table,join in [("demoRuns","r.routeID=t.routeID"),("demoWinners","r.routeID=t.routeID"),("challenges","r.routeID=t.routeID"),("checkpoints","r.routeID=t.finishRouteID"),("playerRuns","r.routeID=(SELECT finishRouteID FROM checkpoints c WHERE c.cpID=t.finishcpID)")]:
  check(sql("SELECT COUNT(*) FROM "+table+" t JOIN routes r ON "+join+" WHERE r.routeName<>CONCAT('renamed_',r.routeID)")=="0",table+" resolves renamed display name after reconnect")
 sql("INSERT INTO routes(mapID,routeName) SELECT mapID,routeName FROM routes LIMIT 1;",fail=True)
 check(True,"duplicate route name on the same map rejected")
 sql("INSERT INTO checkpointRoutes(cpID,routeID) VALUES(-1,-1);",fail=True)
 check(True,"invalid checkpoint/route references rejected")
 for row in originalRoutes:
  rid,hexname=row.split("\t");sql("UPDATE routes SET routeName=0x"+hexname+" WHERE routeID="+rid)
 spec=importlib.util.spec_from_file_location("record72",ROOT/"dev-tools/tests/record-notices-72.py")
 record72=importlib.util.module_from_spec(spec);spec.loader.exec_module(record72)
 report["recordCategoryChecks"]=record72.verify(sql)
 check(report["recordCategoryChecks"]==36,"all 36 exact-mode record comparisons pass with route IDs")
 sql((ROOT/"server-db/migrations/020-database-cleanup.sql").read_text())
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
 print("R174 isolated GSC engine started",flush=True)
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
 report["passed"]=True
finally:
 if engineStarted:report["engineRemoved"]=run(["docker","rm","-f",engine]).returncode==0
 (home/"mods/opencj/route174.cfg").unlink(missing_ok=True)
 if created:report["databaseRemoved"]=run(["docker","rm","-f","-v",name]).returncode==0
 private.unlink(missing_ok=True)
 (home/"result.json").write_text(json.dumps(report,indent=2)+"\n")
 print("R174 result "+str(home/"result.json"),flush=True)
