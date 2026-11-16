"""32-client query-capacity regression: current schema, real GSC SQL and growth data.
Disposable schema-only copy plus synthetic rows. Two shared cores, 1/1.5 GiB caps.
Use --mature --extended-reads --seconds 60 for the hosting workload.
"""
from compose_environment import database_container, database_network, capacity_cpu_set
from pathlib import Path
import sys,threading,os
import argparse,hashlib,json,math,re,secrets,shutil,statistics,struct,subprocess,time,uuid,zlib,runpy
ROOT=Path(__file__).resolve().parents[2]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument("--frames",type=int,default=12000)
parser.add_argument("--seconds",type=int,default=30)
parser.add_argument("--load-batch",type=int,choices=(1,2,4,8,16,32),default=32,help="Diagnostic change in isolated GSC copy only")
parser.add_argument("--load-concurrency",type=int,default=0,help="Diagnostic cap in isolated copy; 0 preserves production")
parser.add_argument("--fps-cache-limit",type=int,choices=(128,256,512),default=512,help="Diagnostic rendered-history cache cap in isolated copy")
parser.add_argument("--db-cpus",type=int,default=0,help="0 matches uncapped development database")
parser.add_argument("--workers",type=int,choices=(4,5),default=4,help="Isolated comparison; five requires an explicit test binary")
parser.add_argument("--binary",type=Path,default=ROOT/"cod4x-server/bin/cod4x18_dedrun")
parser.add_argument("--mature",action="store_true")
parser.add_argument("--extended-reads",action="store_true")
parser.add_argument("--baseline-queries",action="store_true")
parser.add_argument("--cpu-set",help="Two available CPU cores; defaults to the first two allowed cores")
parser.add_argument("--scripts",type=Path,default=ROOT/"server-gsc")
args=parser.parse_args()
try:
    args.cpu_set=capacity_cpu_set(args.cpu_set)
except ValueError as error:
    parser.error(str(error))
mature=args.mature
args.scripts=args.scripts.resolve()
assert args.scripts.is_relative_to(ROOT) and (args.scripts/"opencj").is_dir()
from query_sql import query as source_query

args.binary=args.binary.resolve()
assert args.binary.is_relative_to(ROOT) and args.binary.is_file()
assert args.workers==4 or args.binary!=ROOT/"cod4x-server/bin/cod4x18_dedrun"
assert 0<=args.load_concurrency<=32 and 0<=args.db_cpus<=12
assert max(128,args.seconds*40)<=args.frames<=36000 and 5<=args.seconds<=120
token=uuid.uuid4().hex[:8];tag="sql-capacity-190-"+token
database="opencj_verify_190_"+token+"_cod4"
home=ROOT/"dev-tools/local"/tag;mod=home/"mods/opencj";mod.mkdir(parents=True)
dbname="opencj-capacity-db-"+token;engine="opencj-capacity-engine-"+token
password=secrets.token_hex(24);private=home/"mysql.env";cfg=mod/"capacity.cfg"
private.write_text("MYSQL_ROOT_PASSWORD="+password+"\n");private.chmod(0o600)
created=started=False
report={"players":32,"framesPerDemo":args.frames,"recordedMinutes":args.frames/1200,
        "phaseSeconds":args.seconds,"workers":args.workers,"productionWrites":False,"separateDatabaseContainer":True,"loadBatch":args.load_batch,"loadConcurrency":args.load_concurrency,"databaseCpuLimit":args.db_cpus,"fpsCacheLimit":args.fps_cache_limit}
report["scripts"]=str(args.scripts)
report["extendedReads"]=args.extended_reads
report["baselineQueries"]=args.baseline_queries
binary=args.binary
production_binary=ROOT/"cod4x-server/bin/cod4x18_dedrun"
production_binary_hash=hashlib.sha256(production_binary.read_bytes()).hexdigest()
report["binarySha256"]=hashlib.sha256(binary.read_bytes()).hexdigest()
report["revisions"]={repo:subprocess.check_output(["git","-C",str(ROOT/repo),"rev-parse","HEAD"],text=True).strip() for repo in ("server-gsc","server-ext","cod4x-server","dev-tools")}
source_files=("server-gsc/opencj/mysql.gsc","server-gsc/opencj/demos.gsc","server-gsc/opencj/demorecording.gsc","server-gsc/opencj/menus/runsboard.gsc","server-gsc/opencj/menus/leaderboard.gsc","server-gsc/opencj/showrecords.gsc","server-gsc/opencj/finishsounds.gsc","server-gsc/opencj/recordnotices.gsc")
report["sourceHashes"]={rel:hashlib.sha256((ROOT/rel).read_bytes()).hexdigest() for rel in source_files}
def run(cmd,**kw):return command(cmd,**kw)
def db(sql,source=False):
    target=database_container() if source else dbname
    command=["docker","exec","-i",target,"sh","-c",
             'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql --max_allowed_packet=64M -N -u root']
    p=run(command,input=sql,timeout=90)
    if p.returncode:
        (home/"sql-error.txt").write_text(p.stderr.replace(password,"<redacted>"))
        (home/"sql-error.txt").chmod(0o600)
        raise RuntimeError("SQL fixture error; see restricted sql-error.txt")
    return p.stdout.strip()
def target(sql):return db("USE "+database+";\n"+sql)
def chunks(seed=0):
    result=[]
    for start in range(0,args.frames,64):
        count=min(64,args.frames-start);raw=bytearray(b"OCJ4"+struct.pack("<I",count))
        for j in range(count):
            f=start+j
            x=f*.6+seed*13;y=math.sin(f*.07+seed)*500;z=700+math.sin(f*.11+seed)*200
            flags=517 if f%40<20 else 518
            if f%100<5:flags|=8192
            if f%100==60:flags|=16384
            fps=333 if f%30<15 else 250
            raw+=struct.pack("<fffHHHHHIB",x,y,z,0,(f*137)%65536,0,flags,fps,1,8)
            # Valid native presentation, unarmed, with changing velocity/bob.
            raw+=struct.pack("<HHHBBHBhhhhhhHHHBB",0,0,0,0,f%256,60*256,0,
                             400,200,int(math.cos(f*.11)*800),0,0,0,0,0,0,0,0)
            name=b"none" if j==0 else b""
            raw+=bytes([len(name)])+name
        result.append(zlib.compress(bytes(raw),6).hex())
    return result

def seed():
    target("INSERT INTO mapids(mapID,mapname) VALUES(1,'mp_killhouse');")
    target("INSERT INTO checkpoints(cpID,mapID) VALUES"+",".join(f"({i},1)" for i in range(1,65))+";")
    target("INSERT INTO routes(routeID,mapID,cpID,routeName) VALUES"+",".join(f"({i},1,{i},'capacity{i}')" for i in range(1,65))+";")
    target("UPDATE checkpoints SET finishRouteID=cpID WHERE cpID BETWEEN 1 AND 64;")
    target("INSERT INTO playerInformation(playerID,playerName) VALUES"+",".join(f"({i},'Synthetic {i}')" for i in range(1,513))+";")
    target("INSERT INTO playerRuns(runID,playerID,mapID,finishcpID,finishTimeStamp,instanceNumber,FPSMode,hb) VALUES"+
           ",".join(f"({base+i},{i},1,{i if base!=2000 else 'NULL'},{'NOW()' if base!=2000 else 'NULL'},1,'mix',0)" for base in (1000,2000,3000) for i in range(1,33))+";"+
           "INSERT INTO checkpointStatistics(runID,cpID,timePlayed,saveCount,loadCount,explosiveJumps,explosiveLaunches,doubleExplosives,FPSMode) VALUES"+
           ",".join(f"({base+i},{i},{args.frames*50+i},1,0,0,0,0,'mix')" for base in (1000,3000) for i in range(1,33))+";")
    for start in range(0,10000,500):
        target("INSERT INTO playerRuns(runID,playerID,mapID,finishcpID,finishTimeStamp,FPSMode) VALUES"+
               ",".join(f"({10000+i},{i%512+1},1,1,NOW(),'mix')" for i in range(start,start+500))+";"+
               "INSERT INTO checkpointStatistics(runID,cpID,timePlayed,saveCount,loadCount,explosiveJumps,explosiveLaunches,doubleExplosives,FPSMode) VALUES"+
               ",".join(f"({10000+i},1,{100000+i},20,2,{i%5},0,0,'mix')" for i in range(start,start+500))+";")
    for start in range(0,1000,100):
        target("INSERT INTO playerRuns(runID,playerID,mapID,FPSMode) VALUES"+
               ",".join(f"({20000+i},{i%32+1},1,'mix')" for i in range(start,start+100))+";"+
               "INSERT INTO playerSaves(runID,saveNumber,alpha,beta,gamma,explosiveJumps,doubleExplosives,flags,FPSMode) VALUES"+
               ",".join(f"({20000+i},{j},0,0,0,0,0,0,'mix')" for i in range(start,start+100) for j in range(1,21))+";")
    payloads=chunks()
    report["payloadBytesPerDemo"]=sum(len(x)//2 for x in payloads)
    target("INSERT INTO demoRuns(runID,mapID,routeID,FPSMode,modeMask,timePlayed,explosiveJumps,frameCount,ready) VALUES"+
           ",".join(f"({3000+i},1,{32+i},'mix',0,{args.frames*50},0,{args.frames},1)" for i in range(1,33))+";"+
           "INSERT INTO demoWinners(mapID,routeID,FPSMode,modeMask,kind,runID) SELECT mapID,routeID,FPSMode,modeMask,'walkthrough',runID FROM demoRuns;")
    for i in range(1,33):
        payloads=chunks(i)
        target("INSERT INTO demoChunks(runID,chunkNum,payload) VALUES"+",".join(f"({3000+i},{j},UNHEX('{payload}'))" for j,payload in enumerate(payloads))+";")
    report["syntheticRows"]={"finishedRuns":10064,"unfinishedRuns":1032,"saves":20000,"players":512}
    if mature:
        print("HOSTING seeding 250000 historical finishes and 2000000 saves across 100 older maps",flush=True)
        target("CREATE TABLE hostingDigits(n INT PRIMARY KEY); INSERT INTO hostingDigits VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9);"+
               "CREATE TABLE hostingNums(n INT PRIMARY KEY); INSERT INTO hostingNums SELECT a.n+10*b.n+100*c.n+1000*d.n FROM hostingDigits a CROSS JOIN hostingDigits b CROSS JOIN hostingDigits c CROSS JOIN hostingDigits d;")
        target("INSERT INTO playerInformation(playerID,playerName) SELECT 513+n,CONCAT('Synthetic ',513+n) FROM hostingNums WHERE n<9488;"+
               "INSERT INTO mapids(mapID,mapname) SELECT 101+n,CONCAT('hosting_map_',n) FROM hostingNums WHERE n<100;"+
               "INSERT INTO checkpoints(cpID,mapID) SELECT 100001+n,101+n FROM hostingNums WHERE n<100;")
        for start in range(0,250000,10000):
            target(f"INSERT INTO playerRuns(runID,playerID,mapID,finishcpID,finishTimeStamp,timePlayed,FPSMode) SELECT 100000+n+{start},1+MOD(n+{start},10000),IF(n+{start}<50000,1,101+MOD(n+{start},100)),IF(n+{start}<50000,1,100001+MOD(n+{start},100)),NOW(),100000+n,'mix' FROM hostingNums;"+
                   f"INSERT INTO checkpointStatistics(runID,cpID,timePlayed,saveCount,loadCount,explosiveJumps,explosiveLaunches,doubleExplosives,FPSMode) SELECT 100000+n+{start},IF(n+{start}<50000,1,100001+MOD(n+{start},100)),100000+n,100,10,2,2,0,'mix' FROM hostingNums;")
            if start%50000==0:print("HOSTING seeded finishes",start+10000,flush=True)
        for start in range(0,20000,10000):
            target(f"INSERT INTO playerRuns(runID,playerID,mapID,timePlayed,FPSMode) SELECT 1000000+n+{start},1+MOD(n+{start},10000),IF(n+{start}<2000,1,101+MOD(n+{start},100)),100000+n,'mix' FROM hostingNums;")
        for start in range(0,2000000,10000):
            target(f"INSERT INTO playerSaves(runID,saveNumber,x,y,z,alpha,beta,gamma,explosiveJumps,doubleExplosives,flags,FPSMode) SELECT 1000000+FLOOR((n+{start})/100),MOD(n+{start},100),n*0.1234,n*0.2345,n*0.3456,1,90,1,2,0,0,'mix' FROM hostingNums;")
            if start%250000==0:print("HOSTING seeded saves",start+10000,flush=True)
        report["syntheticRows"].update({"extraFinishedRuns":250000,"extraUnfinishedRuns":20000,"extraSaves":2000000,"totalPlayers":10000,"extraMaps":100})
        target("ANALYZE TABLE playerSaves,playerRuns,checkpointStatistics,demoChunks;")
    report["storageAfterSeed"]=target("SELECT TABLE_NAME,TABLE_ROWS,DATA_LENGTH,INDEX_LENGTH FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME IN ('playerRuns','playerSaves','checkpointStatistics','demoChunks','demoRuns');")
    report["dbMemorySettings"]=target("SHOW VARIABLES WHERE Variable_name IN ('innodb_buffer_pool_size','max_connections','temptable_max_ram','tmp_table_size');")

def quantiles(values):
    if not values:return {}
    x=sorted(values)
    return {"count":len(x),"median":statistics.median(x),"p95":x[math.ceil(.95*len(x))-1],"p99":x[math.ceil(.99*len(x))-1],"max":max(x)}
override=home/'limits.yaml'
override.write_text('services:\n  server:\n    mem_limit: 1024m\n    memswap_limit: 1024m\n    cpuset: "'+args.cpu_set+'"\n    cpus: 2.0\n')
resources={'profile':'query-audit-extended' if args.extended_reads else 'query-audit','containers':{},'samples':[]}
paths={};lock=threading.Lock();stop=threading.Event()
def sample():
    row={'at':round(time.monotonic(),3)}
    for name,path in list(paths.items()):
        try:
            stat=dict(line.split() for line in (path/'memory.stat').read_text().splitlines())
            def val(file):return int((path/file).read_text().strip())
            row[name]={'current':val('memory.current'),'peak':val('memory.peak'),'anon':int(stat['anon']),'file':int(stat['file']),
                       'events':(path/'memory.events').read_text().strip(),'cpu':(path/'cpu.stat').read_text().strip()}
        except (OSError,ValueError,KeyError):continue
    if len(row)>1:
        with lock:resources['samples'].append(row)
def monitor():
    while not stop.wait(.5):sample()
thread=threading.Thread(target=monitor,daemon=True);thread.start()
def command(cmd,**kw):
    cmd=list(cmd)
    if cmd[:3]==['docker','run','-d']:
        assert '--name' in cmd and cmd[cmd.index('--name')+1].startswith('opencj-capacity-db-')
        cmd[2:2]=['--cpuset-cpus',args.cpu_set,'--memory-swap','1536m']
        cmd+=['--innodb-buffer-pool-size=536870912','--temptable-max-ram=67108864','--max-connections=40']
    if cmd[:3]==['docker','compose','run'] and '--name' in cmd:
        cmd[2:2]=['-f',str(ROOT/'dev-tools/compose.yaml'),'-f',str(override)]
    if cmd[:2]==['docker','rm']:sample()
    result=subprocess.run(cmd,capture_output=True,text=True,**kw)
    if result.returncode==0 and '--name' in cmd and cmd[0]=='docker':
        name=cmd[cmd.index('--name')+1]
        if name.startswith(('opencj-capacity-db-','opencj-capacity-engine-')):
            meta=json.loads(subprocess.check_output(['docker','inspect',name],text=True))[0]
            pid=meta['State']['Pid']
            group=Path('/proc')/str(pid)/'cgroup'
            rel=group.read_text().strip().split('::')[-1]
            paths[name]=Path('/sys/fs/cgroup')/rel.lstrip('/')
            resources['containers'][name]={'memoryLimit':meta['HostConfig']['Memory'],'memorySwapLimit':meta['HostConfig']['MemorySwap'],'cpuset':meta['HostConfig']['CpusetCpus'],'nanoCpus':meta['HostConfig']['NanoCpus']}
            sample()
    return result


def capacity_menu():
    template=(ROOT/"dev-tools/tests/query-capacity-menu.gsc").read_text()
    settings={"before":args.baseline_queries,"script_root":args.scripts}
    texts={
      "LBQUERY":source_query("leaderboard",**settings),
      "RNQUERY":source_query("runs",player=987654321,sort="timePlayed ASC, timePlayed ASC, explosiveJumps ASC, loadCount ASC, saveCount ASC, startTimeStamp ASC",**settings),
      "HUDQUERY":source_query("hud",current=987654321,**settings)}
    for key,value in texts.items():
        template=template.replace(key," + (10000+i) + ".join(json.dumps(p) for p in value.split("987654321")) if key=="HUDQUERY" else
                                  " + (i+1) + ".join(json.dumps(p) for p in value.split("987654321")))
    return template

try:
    image=run(["docker","inspect","-f","{{.Config.Image}}",database_container()]).stdout.strip()
    network=database_network()
    assert image=="mysql:8.0"
    p=run(["docker","run","-d","--name",dbname,"--network",network,"--memory","1536m"]+
          (["--cpus",str(args.db_cpus)] if args.db_cpus else [])+
          ["--env-file",str(private),image,"--log-bin-trust-function-creators=1"])
    assert p.returncode==0,"Disposable database launch failed"
    created=True
    for _ in range(90):
        p=run(["docker","exec",dbname,"sh","-c",'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql --protocol=TCP -h127.0.0.1 -N -u root -e "SELECT 1"'])
        if p.returncode==0:break
        time.sleep(1)
    else:raise RuntimeError("Disposable database did not become ready")
    dump=run(["docker","exec",database_container(),"sh","-c",
              'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump -u root --no-data --routines --triggers --skip-comments --skip-lock-tables --no-tablespaces --set-gtid-purged=OFF --column-statistics=0 openCJ_cod4'])
    assert dump.returncode==0 and not re.search(r"^INSERT INTO",dump.stdout,re.M)
    schema=dump.stdout.replace("openCJ_cod4",database)
    schema=re.sub(r"DEFINER=\S+\s", "DEFINER=CURRENT_USER ",schema)
    assert not re.search(r"^\s*(CREATE DATABASE|USE)\b",schema,re.I|re.M)
    report["sourceSchemaSha256"]=hashlib.sha256(dump.stdout.encode()).hexdigest()
    db("CREATE DATABASE "+database+" CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;")
    target(schema)
    migration=(ROOT/"server-db/migrations/018-demo-publication.sql").read_text()
    # Schema-only copy already contains stable route publication.
    index_count=int(target("SELECT COUNT(DISTINCT INDEX_NAME) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='checkpointStatistics' AND INDEX_NAME IN ('checkpoint_time','checkpoint_rpg');"))
    assert index_count in (0,2),"Partially installed ranking indexes"
    if index_count==0:target((ROOT/"server-db/migrations/026-query-ranking-indexes.sql").read_text())
    columns=target("SELECT GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='checkpointStatistics' AND INDEX_NAME='checkpoint_time';")
    assert columns=='cpID,timePlayed,explosiveJumps,runID,loadCount,saveCount',"Ranking covering index differs from migration 026"

    report["publicationMigrationSha256"]=hashlib.sha256(migration.encode()).hexdigest()
    db("CREATE USER 'capacity'@'%' IDENTIFIED BY '"+password+"'; GRANT ALL PRIVILEGES ON "+database+".* TO 'capacity'@'%';")
    print("CAPACITY isolated database ready; seeding synthetic records.",flush=True)
    seed()
    report["publicationSQL"]={"checks":0,"note":"Old route-name failure-injection suite omitted; current-schema publication exercised by workload."}
    print("CAPACITY publication concurrency/failure checks: "+str(report["publicationSQL"]["checks"]),flush=True)
    for folder in ("opencj","maps"):shutil.copytree(args.scripts/folder,mod/folder)
    assert args.load_batch==32 and args.load_concurrency==0 and args.fps_cache_limit==512, "Use unchanged production paths for acceptance"
    for asset in ("mod.ff","z_opencj.iwd"):(mod/asset).symlink_to("/mod-assets/"+asset)
    (home/"plugins").mkdir();(home/"steamclient.so").symlink_to("/game/steamclient.so")

    shutil.copyfile(ROOT/"dev-tools/tests/sql-capacity-190.gsc",mod/"opencj/sqlcapacity.gsc")
    p=mod/"opencj/sqlcapacity.gsc";fixture=p.read_text()
    fixture=fixture.replace('stats[0]==4 &&',f'stats[0]=={args.workers} &&').replace('four workers and empty completion backlog','configured workers and empty completion backlog')
    fixture=fixture.replace("    clipTransfers();","    level.demoPublicationReady=true;\n    clipTransfers();")
    fixture=fixture.replace("tick%10==0","tick%200==((i*6)%200)").replace("tick%20==0","tick%120==((i*3)%120)")
    import re
    menu=capacity_menu()
    fixture=re.sub(r"menu\(i,tick\)\n\{.*?(?=progress\(i,tick\))",lambda m:menu+"\n",fixture,flags=re.S)
    if args.extended_reads:
        fixture=fixture.replace('            if((tick<level.capTicks || level.demoPersisting>0) && tick%120==((i*3)%120))p thread progress(i,tick);',
            '            if((tick<level.capTicks || level.demoPersisting>0) && tick%120==((i*3)%120))p thread progress(i,tick);\n            if(tick<level.capTicks && tick%400==((i*12)%400))p thread auditRead(i);')
    p.write_text(fixture)
    shutil.copyfile(ROOT/"dev-tools/tests/demo-publication-190.gsc",mod/"opencj/publicationcapacity.gsc")
    (mod/"maps/mp/gametypes/cj.gsc").write_text('main(){level.script=getCvar("mapname");}\n')
    (mod/"maps/mp/gametypes/_callbacksetup.gsc").write_text(
        'CodeCallback_StartGameType(){thread openCJ\\sqlCapacity::main();}\n'+
        "\n".join("CodeCallback_"+c+"(){}" for c in ("PlayerConnect","PlayerDisconnect","PlayerDamage","PlayerKilled","PlayerLastStand")))
    (mod/"maps/mp/mp_killhouse.gsc").write_text("main(){}\n")
    p=mod/"opencj/mysql.gsc";s=p.read_text()
    initializer='level.database["port"], 4);'
    assert s.count(initializer)==1
    s=s.replace(initializer,f'level.database["port"], {args.workers});')
    needle='    id=mysql_async_submit(query, policy, key, scope, deadline, int(save));'
    assert s.count(needle)==1;s=s.replace(needle,'    capacityStarted=capacityClock();\n'+needle)
    needle='    result.rows=rows;\n    result.status=outcome[0];'
    assert s.count(needle)==1
    s=s.replace(needle,'    openCJ\\sqlCapacity::queryMetric(policy,capacityStarted,outcome);\n'+needle)
    needle='    ret = mysql_query(level.mySQL, query);'
    assert s.count(needle)==1
    s=s.replace(needle,'    capacityStarted=capacityClock();\n'+needle+'\n    printf("CAP SQL "+level.capStage+" 5 "+(capacityClock()-capacityStarted)+" "+ret+" 0 0\\n");')
    needle='    printf("CAP SQL "+level.capStage+" 5 "'
    assert s.count(needle)==1
    s=s.replace(needle,'    printf("CAP SYNC "+level.capStage+" "+capacityStarted+" "+(capacityClock()-capacityStarted)+"\\n");'+chr(10)+needle)
    declaration="_request(query, policy, key, scope, deadline, save)\n{"
    assert s.count(declaration)==1
    s=s.replace(declaration,"_capacityRealRequest(query, policy, key, scope, deadline, save)\n{")
    s+=r"""
_request(query, policy, key, scope, deadline, save)
{
    return openCJ\publicationCapacity::request(query,policy,key,scope,deadline,save);
}
"""
    p.write_text(s)
    cfg.write_text(f'set db_host "{dbname}"\nset db_user "capacity"\nset db_pass "{password}"\nset db_base "{database[:-1]}"\nset db_port "3306"\nset capacity_database "{database}"\n')
    cfg.chmod(0o600)
    relative=str(home.relative_to(ROOT))
    build=run(["docker","compose","run","--rm","--no-deps","build","bash","-lc",
               "g++ -m32 -std=c++11 -fPIC -shared /workspace/dev-tools/tests/sql-capacity-clock.cpp -o /workspace/"+relative+"/plugins/capacity_clock.so"],cwd=ROOT/"dev-tools",timeout=90)
    (home/"build.log").write_text(build.stdout+build.stderr)
    assert build.returncode==0,"Clock plugin build failed"
    cmd=["docker","compose","run","-d","--no-deps","--name",engine,"--workdir", "/workspace/" + str(home.relative_to(ROOT)), "server","/workspace/"+str(binary.relative_to(ROOT))]
    for key,value in [("fs_basepath","/game"),("fs_homepath","/workspace/"+relative),("fs_game","mods/opencj"),("dedicated",2),
                      ("net_port",28975),("sv_maxclients",32),("sv_authorizemode",0),("com_hunkMegs",1024),("developer",1),
                      ("g_gametype","cj"),("capacity_frames",args.frames),("capacity_ticks",args.seconds*20)]:
        cmd+=["+set",key,str(value)]
    cmd+=["+exec","capacity.cfg","+loadplugin","capacity_clock","+map","mp_killhouse"]
    p=run(cmd,cwd=ROOT/"dev-tools");assert p.returncode==0,"Isolated engine launch failed";started=True
    print("CAPACITY isolated engine started: "+str(home),flush=True)
    seen=0;log=""
    for _ in range(600):
        time.sleep(1)
        p=run(["docker","logs",engine]);log=(p.stdout+p.stderr).replace(password,"<redacted>")
        lines=log.splitlines()
        for line in lines[seen:]:
            if line.startswith(("CAP BEGIN","CAP END","CAP COMPLETE","CAP FAILURE")):print(line,flush=True)
        seen=len(lines)
        if any(v in log for v in ("CAP COMPLETE","script compile error","script runtime error","Received signal:","exceeded maximum number")):break
    (home/"console.log").write_text(log);(home/"console.log").chmod(0o600)
    if any(v in log for v in ("script compile error","script runtime error","Received signal:","exceeded maximum number")):
        for marker in ("script compile error","script runtime error","Received signal:","exceeded maximum number"):
            if marker in log:print(log[max(0,log.index(marker)-100):log.index(marker)+1600],flush=True)
    phases={}
    for name in ("record32","mixed16","finish32_watch32","shared32"):
        metrics={}
        sql=[tuple(map(int,m)) for m in re.findall(r"CAP SQL "+name+r" (\d+) (\d+) (\d+) (\d+) (\d+)",log)]
        for policy,label in ((0,"progress"),(1,"read"),(2,"upload"),(3,"menu"),(4,"write"),(5,"synchronous")):
            values=[x for x in sql if x[0]==policy]
            if values:
                metrics[label]={"completionMs":quantiles([x[1] for x in values]),"queueMs":quantiles([x[3] for x in values]),
                                "executionMs":quantiles([x[4] for x in values]),"outcomes":{str(o):sum(x[2]==o for x in values) for o in set(x[2] for x in values)}}
        metrics["demoLoadMs"]=quantiles([int(m) for m in re.findall(r"CAP LOAD "+name+r" \d+ (\d+)",log)])
        metrics["demoUploadMs"]=quantiles([int(m) for m in re.findall(r"CAP UPLOAD "+name+r" \d+ (\d+)",log)])
        end=re.search(r"CAP END "+name+r" (\d+) (\d+) (\d+) (\d+)",log)
        if end:metrics.update(dict(zip(("wallMs","ticks","peakJobs","peakQueryBytes"),map(int,end.groups()))))
        phases[name]=metrics
    report["frameIntervals"]={name:dict(zip(("samples","p95Ms","p99Ms","maxMs","over75Ms"),map(int,m[1:]))) for m in re.findall(r"CAP TICKS (\d+) (\d+) (\d+) (\d+) (\d+) (\d+)",log) for name in [("setup","record32","mixed16","finish32_watch32","shared32")[int(m[0])]]}
    report["hitches"]=[dict(zip(("stage","endedAtMs","intervalMs"),map(int,m))) for m in re.findall(r"CAP HITCH (\d+) (\d+) (\d+)",log)]
    sync=[(stage,int(start),int(duration)) for stage,start,duration in re.findall(r"CAP SYNC (\w+) (\d+) (\d+)",log)]
    for hitch in report["hitches"]:
        start=hitch["endedAtMs"]-hitch["intervalMs"];end=hitch["endedAtMs"]
        calls=[duration for _,at,duration in sync if start<=at<end]
        hitch.update(synchronousCalls=len(calls),synchronousMs=sum(calls))
    report["phases"]=phases
    report["liveBinaryUnchanged"]=production_binary_hash==hashlib.sha256(production_binary.read_bytes()).hexdigest()
    complete=re.search(r"CAP COMPLETE (\d+) (\d+)",log)
    report["completed"]=bool(complete);report["failures"]=int(complete[1]) if complete else None
    report["checks"]=int(complete[2]) if complete else 0
    report["verificationPassed"]=bool(complete and int(complete[1])==0)
    report["binaryUnchanged"]=hashlib.sha256(binary.read_bytes()).hexdigest()==report["binarySha256"]
    print(json.dumps({"verificationPassed":report["verificationPassed"],"checks":report["checks"],"frameIntervals":report["frameIntervals"],"phases":{k:{"wallMs":v.get("wallMs"),"progressP95":v.get("progress",{}).get("completionMs",{}).get("p95"),"menuP95":v.get("menu",{}).get("completionMs",{}).get("p95"),"demoLoadMs":v["demoLoadMs"],"demoUploadMs":v["demoUploadMs"]} for k,v in phases.items()}}),flush=True)
    assert report["verificationPassed"],"Capacity verification did not pass"
    assert report["liveBinaryUnchanged"],"Production executable changed during isolated comparison"
finally:
    report["binaryUnchanged"]=hashlib.sha256(binary.read_bytes()).hexdigest()==report["binarySha256"]
    report["productionSourcesUnchanged"]=all(hashlib.sha256((ROOT/rel).read_bytes()).hexdigest()==value for rel,value in report["sourceHashes"].items())
    if started:
        p=run(["docker","logs",engine]);(home/"console.log").write_text((p.stdout+p.stderr).replace(password,"<redacted>"));(home/"console.log").chmod(0o600)
        p=run(["docker","rm","-f",engine]);report["engineRemoved"]=p.returncode==0
    if created:
        p=run(["docker","rm","-f","-v",dbname]);report["databaseContainerRemoved"]=p.returncode==0
    private.unlink(missing_ok=True);cfg.unlink(missing_ok=True)
    report["credentialsRemoved"]=not private.exists() and not cfg.exists()
    stop.set();thread.join(timeout=2);sample()
    (home/"hosting-resources.json").write_text(json.dumps(resources,indent=2))
    (home/"result.json").write_text(json.dumps(report,indent=2)+"\n")
    print("CAPACITY evidence "+str(home)+"; cleanup "+str(report.get("engineRemoved"))+"/"+str(report.get("databaseContainerRemoved")),flush=True)
