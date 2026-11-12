"""Read-only #109 catalogue audit and session-local SQL exclusion fixtures."""
from pathlib import Path
import argparse,json,re,subprocess
ROOT=Path(__file__).resolve().parents[2]
def query():
    text=(ROOT/"server-gsc/opencj/maproutes.gsc").read_text()
    body=text.split("query()\n{",1)[1].split("\n}",1)[0]
    return "".join(re.findall(r'"([^"]*)"',body))
def db(sql):
    p=subprocess.run(["docker","exec","-i","opencj-dev-db-1","sh","-c",
        'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -N -u root openCJ_cod4'],
        input=sql,text=True,capture_output=True)
    if p.returncode:raise RuntimeError("Map-route SQL verification failed: "+p.stderr.strip())
    return [line.split("\t") for line in p.stdout.strip().splitlines() if line]
def run(output):
    output.mkdir(parents=True,exist_ok=True)
    sql=query()
    rows=db("START TRANSACTION READ ONLY;"+sql+";COMMIT;")
    pool={row[0] for row in db("SELECT mapname FROM mapids WHERE inRotation=1;")}
    expected=db("SELECT m.mapname,r.routeName FROM routes r JOIN checkpoints c ON c.cpID=r.cpID JOIN mapids m ON m.mapID=c.mapID WHERE m.inRotation=1 AND c.retired=0 AND r.routeType='normal' ORDER BY m.mapname,r.routeName;")
    selected=[row for row in rows if row[0] in pool]
    available={(x[0],x[1]) for x in selected}
    # The legacy Bouncer Training "normal" anchor has no separate finish.
    assert {tuple(x) for x in expected}-available=={("mp_bouncer_training","normal")}
    assert available<={tuple(x) for x in expected}
    assert len(pool)==10 and len(selected)==25
    # Temporary tables shadow the real names only inside this SQL connection.
    fixture="""
CREATE TEMPORARY TABLE mapids(mapID INT,mapname VARCHAR(128));
CREATE TEMPORARY TABLE checkpoints(cpID INT,mapID INT,retired INT,ender VARCHAR(50));
CREATE TEMPORARY TABLE routes(cpID INT,routeName VARCHAR(50),routeType VARCHAR(10),colorRGB INT,routeShaderColor VARCHAR(10));
INSERT INTO mapids VALUES(1,'fixture_map'),(2,'other_map');
INSERT INTO checkpoints VALUES(1,1,0,NULL),(2,1,0,'easy'),(3,1,0,NULL),(4,2,0,'unfinished'),(5,1,1,NULL),(6,1,0,'retiredstart'),(7,1,0,NULL),(8,1,1,'retiredfinish'),(9,1,0,NULL),(10,1,0,'bonus'),(11,1,0,NULL),(12,1,0,'secret'),(13,1,0,NULL),(14,1,0,'hard'),(15,1,0,NULL),(16,1,0,'custom');
INSERT INTO routes VALUES(1,'easy','normal',65280,NULL),(3,'unfinished','normal',255,NULL),(5,'retiredstart','normal',255,NULL),(7,'retiredfinish','normal',255,NULL),(9,'bonus','bonus',255,NULL),(11,'secret','secret',255,NULL),(13,'hard','normal',NULL,'red'),(15,'custom','normal',NULL,NULL);
"""
    got=db(fixture+"CREATE TEMPORARY TABLE finishFixture AS SELECT * FROM checkpoints;"+sql.replace("FROM checkpoints e","FROM finishFixture e")+";")
    assert got==[["fixture_map","easy","65280"],["fixture_map","hard","16711680"],["fixture_map","custom","16777215"]],got
    checks=["ten pool maps covered","all 25 finished normal pool routes included","same-map finish required",
            "retired start omitted","retired finish omitted","bonus omitted","secret omitted",
            "route order","exact RGB retained","legacy shader fallback","neutral missing-color fallback"]
    report={"checks":len(checks),"failures":0,"poolMaps":len(pool),"poolRoutes":len(selected),"productionWrites":False,"checksPassed":checks}
    (output/"sql-result.json").write_text(json.dumps(report,indent=2)+"\n")
    (output/"route-catalogue.json").write_text(json.dumps(rows,indent=2)+"\n")
    gsc=["rows()","{","    result=[];"]
    for row in rows:
        gsc.append("    row=[];")
        for i,value in enumerate(row):gsc.append("    row["+str(i)+"]="+json.dumps(value)+";")
        gsc.append("    result[result.size]=row;")
    gsc+=["    return result;","}"]
    (output/"maproutecataloguedata.gsc").write_text("\n".join(gsc)+"\n")
    print(json.dumps(report),flush=True)
if __name__=="__main__":
    p=argparse.ArgumentParser(description=__doc__);p.add_argument("output",type=Path)
    run(p.parse_args().output)
