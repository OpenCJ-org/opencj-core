"""Execute engine-generated #184 selection queries against temporary SQL fixtures."""
from compose_environment import database_container
from pathlib import Path
import argparse, json, re, subprocess

def run(log):
    queries=dict(re.findall(r"DEMO SELECTION QUERY (\w+) (SELECT[^\n]+)",log.read_text()))
    assert set(queries)=={"walkthrough","speedrun","lowrpg","nearby"}
    fixture="""
CREATE TEMPORARY TABLE demoRuns(runID INT,modeMask INT,frameCount INT,ready INT,timePlayed INT,explosiveJumps INT,FPSMode VARCHAR(8));
CREATE TEMPORARY TABLE demoWinners(runID INT,mapID INT,routeName VARCHAR(50),kind VARCHAR(20),modeMask INT,FPSMode VARCHAR(8));
"""
    # Unique fake winners cover eligible route/FPS/mode combinations, excluded
    # maps/routes/modes/readiness, stable ties, and spatial fallback candidates.
    records=[
        (1,7,'easy',0,'mix',1,100,0),
        (2,7,'hard',0,'mix',1,90,2),
        (3,7,'easy',4,'mix',1,80,0),
        (4,7,'easy',2,'mix',1,70,0),
        (5,7,'other',0,'mix',1,60,0),
        (6,8,'easy',0,'mix',1,50,0),
        (7,7,'easy',0,'hax',1,40,0),
        (8,7,'easy',0,'125',1,95,1),
        (9,7,'hard',0,'125',0,30,0),
        (10,7,'hard',0,'mix',1,90,2),
        (11,7,'hard',1,'mix',1,20,0),
    ]
    for ident,mapid,route,mask,fps,ready,seconds,shots in records:
        fixture+=f"INSERT INTO demoRuns VALUES({ident},{mask},100,{ready},{seconds},{shots},'{fps}');\n"
        for kind in ("walkthrough","speedrun","lowrpg"):
            fixture+=f"INSERT INTO demoWinners VALUES({ident},{mapid},'{route}','{kind}',{mask},'{fps}');\n"
    sql=fixture+"\n".join(f"SELECT '{kind}';{query};" for kind,query in queries.items())
    result=subprocess.run(["docker","exec","-i",database_container(),"sh","-c",
        'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -N -u root openCJ_cod4'],
        input=sql,text=True,capture_output=True)
    assert result.returncode==0,result.stderr
    actual={};kind=None
    for line in result.stdout.splitlines():
        if line in queries:kind=line;actual[kind]=[]
        else:actual[kind].append(int(line.split("\t")[0]))
    expected={"walkthrough":[2,10,1],"speedrun":[3,2,10,8,1],
              "lowrpg":[1,8,2,10],"nearby":[5,2,10,8,1]}
    assert actual==expected,(actual,expected)
    report={"failures":0,"queryChecks":len(expected),"selectedRunIDs":actual,
            "covers":["shared routes","mode subsets","walkthrough clean modes",
                      "hax walkthrough uses mix","compatible FPS","readiness",
                      "same map","stable ties","speedrun time order",
                      "low-RPG order","no stale route in spatial fallback"],
            "productionWrites":False}
    (log.parent/"selection-sql.json").write_text(json.dumps(report,indent=2)+"\n")
    print(json.dumps(report),flush=True)

if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log",type=Path)
    run(parser.parse_args().log)
