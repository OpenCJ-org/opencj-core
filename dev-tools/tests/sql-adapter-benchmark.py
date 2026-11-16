"""Compare the real #192 binary with the new pool using identical admitted work."""
from compose_environment import workspace_file
from pathlib import Path
import subprocess, time, re, statistics, hashlib
GSC = r"""
main()
{
    db=getCvar("history192_database");
    if(getSubStr(db,0,18)!="opencj_verify_192_")return;
    conn=mysql_init();
    mysql_real_connect(conn,getCvar("db_host"),getCvar("db_user"),getCvar("db_pass"),db,int(getCvar("db_port")));
    mysql_query(conn,"CREATE TABLE IF NOT EXISTS adapter_bench(value INT) ENGINE=InnoDB");
    mysql_store_result(conn);
    mysql_async_initializer(getCvar("db_host"),getCvar("db_user"),getCvar("db_pass"),db,int(getCvar("db_port")),4);
    printf("SQLBENCH STARTED\n");
    for(trial=0;trial<5;trial++)
    {
        for(i=0;i<40;i++)
        {
            id=menuQuery("SELECT SLEEP(0.05),1");
            if(!isDefined(id) || id<=0){printf("SQLBENCH FAILURE admission\n");return;}
        }
        start=getTime();
        progress=progressQuery("INSERT INTO adapter_bench VALUES(1)");
        done=0;latency=-1;
        for(waiting=0;waiting<200 && done<41;waiting++)
        {
            list=mysql_async_getdone_list();
            for(j=0;j<list.size;j++)
            {
                result=mysql_async_getresult_and_free(list[j]);
                if(!isDefined(result)){printf("SQLBENCH FAILURE query\n");return;}
                if(result!=0)mysql_free_result(result);
                if(list[j]==progress)latency=getTime()-start;
                done++;
            }
            if(done<41)wait 0.05;
        }
        if(done!=41 || latency<0){printf("SQLBENCH FAILURE completion\n");return;}
        printf("SQLBENCH LATENCY "+latency+"\n");
    }
    printf("SQLBENCH COMPLETE\n");
}
menuQuery(query) { return MENU_SUBMIT; }
progressQuery(query) { return PROGRESS_SUBMIT; }
"""
def run_benchmark(root, home, private, redact, baseline_binary):
    baseline_binary=workspace_file(baseline_binary)
    report={}
    for variant in ("baseline","bounded"):
        target=home/("bench-"+variant);mod=target/"mods/opencj";mod.mkdir(parents=True)
        (mod/"opencj").mkdir();(mod/"maps/mp/gametypes").mkdir(parents=True)
        text=GSC.replace("MENU_SUBMIT","mysql_async_create_query(query)" if variant=="baseline" else 'mysql_async_submit(query,3,"","bench",10000,1)')
        text=text.replace("PROGRESS_SUBMIT","mysql_async_create_query(query)" if variant=="baseline" else 'mysql_async_submit(query,0,"run:bench","",10000,1)')
        (mod/"opencj/sqlbench.gsc").write_text(text)
        (mod/"maps/mp/gametypes/cj.gsc").write_text('main() { level.script=getCvar("mapname"); }\n')
        (mod/"maps/mp/gametypes/_callbacksetup.gsc").write_text(
            'CodeCallback_StartGameType() { thread openCJ\\sqlBench::main(); }\n'+
            "\n".join("CodeCallback_"+callback+"() {}" for callback in
             ["PlayerConnect","PlayerDisconnect","PlayerDamage","PlayerKilled","PlayerLastStand"]))
        (mod/"maps/mp/mp_killhouse.gsc").write_text("main() {}\n")
        for asset in ("mod.ff","z_opencj.iwd"):(mod/asset).symlink_to("/mod-assets/"+asset)
        cfg=mod/"history192.cfg";cfg.write_bytes(private.read_bytes());cfg.chmod(0o600)
        (target/"steamclient.so").symlink_to("/game/steamclient.so")
        (target/"plugins").mkdir()

        name="opencj-sqlbench-"+home.name[-8:]+"-"+variant
        binary=baseline_binary if variant=="baseline" else root/"cod4x-server/bin/cod4x18_dedrun"
        command=["docker","compose","run","-d","--no-deps","--name",name,"--workdir", "/workspace/" + str(target.relative_to(root)), "server","/workspace/"+str(binary.relative_to(root))]
        for key,value in [("fs_basepath","/game"),("fs_homepath","/workspace/"+str(target.relative_to(root))),
            ("fs_game","mods/opencj"),("dedicated","2"),("net_port","28973"),("sv_maxclients","2"),
            ("sv_authorizemode","0"),("com_hunkMegs","1024"),("developer","1"),("g_gametype","cj")]:
            command+=["+set",key,value]
        command+=["+exec","history192.cfg","+map","mp_killhouse"]
        started=False
        try:
            subprocess.run(command,cwd=root/"dev-tools",check=True,capture_output=True);started=True
            log=""
            for _ in range(45):
                time.sleep(1)
                proc=subprocess.run(["docker","logs",name],capture_output=True,text=True)
                log=redact(proc.stdout+proc.stderr)
                if "SQLBENCH COMPLETE" in log or "SQLBENCH FAILURE" in log or "script compile error" in log or "script runtime error" in log:break
            path=target/"console.log";path.write_text(log);path.chmod(0o600)
            latencies=[int(v) for v in re.findall(r"SQLBENCH LATENCY (\d+)",log)]
            assert "SQLBENCH COMPLETE" in log and len(latencies)==5, "Benchmark incomplete: "+str(path)
            report[variant]={"latenciesMs":latencies,"medianMs":statistics.median(latencies),
                             "binarySha256":hashlib.sha256(binary.read_bytes()).hexdigest(),"menuQueriesPerTrial":40,"workers":4}
            print("SQLBENCH",variant,report[variant],flush=True)
        finally:
            cfg.unlink(missing_ok=True)
            if started:subprocess.run(["docker","rm","-f",name],check=True,capture_output=True)
    assert report["bounded"]["medianMs"]<report["baseline"]["medianMs"]/2,"Progress latency did not improve"
    return report
