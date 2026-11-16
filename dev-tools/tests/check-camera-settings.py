"""Replay actual camera setting writes into connection-local temporary tables."""
from pathlib import Path
import argparse,json,re,subprocess

def run(log):
    writes=re.findall(r"^CAMERA SQL (CALL setPlayerSetting\([^\n]+\))$",log.read_text(),re.M)
    assert len(writes)==6,(len(writes),writes)
    assert all(re.fullmatch(r"CALL setPlayerSetting\(7, '(thirdpersondistance|thirdpersonangle)', '-?\d+'\)",q) for q in writes)
    sql="CREATE TEMPORARY TABLE settings(settingID INT NOT NULL AUTO_INCREMENT PRIMARY KEY,settingName VARCHAR(256) NOT NULL UNIQUE);CREATE TEMPORARY TABLE playerSettings(playerID INT NOT NULL,settingID INT NOT NULL,value VARCHAR(256),PRIMARY KEY(playerID,settingID));\n"
    sql+=";\n".join(writes)+";\n"
    # This is the same shape read by settings::loadSettingsFromDatabase.
    sql+="SELECT a.settingName,b.value FROM settings a INNER JOIN playerSettings b ON a.settingID=b.settingID WHERE b.playerID=7 ORDER BY a.settingName;"
    sql+="SELECT COUNT(*) FROM playerSettings;"
    result=subprocess.run(["docker","exec","-i","opencj-dev-db-1","sh","-c",
        'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -N -u root openCJ_cod4'],
        input=sql,text=True,capture_output=True)
    assert result.returncode==0,result.stderr
    rows=[line.split("\t") for line in result.stdout.strip().splitlines()]
    expected=[["thirdpersonangle","90"],["thirdpersondistance","180"],["2"]]
    assert rows==expected,rows
    report={"checks":3,"failures":0,"capturedWrites":len(writes),"storedValues":dict(rows[:-1]),"productionWrites":False}
    (log.parent/"settings-sql.json").write_text(json.dumps(report,indent=2)+"\n")
    print(json.dumps(report),flush=True)
if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument("log",type=Path)
    run(parser.parse_args().log)
