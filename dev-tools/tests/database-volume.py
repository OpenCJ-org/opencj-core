"""Verify external database volume protection using a disposable probe only."""
from pathlib import Path
import json,re,subprocess,uuid
ROOT=Path(__file__).resolve().parents[2]
tag="opencj-volume-safety-"+uuid.uuid4().hex[:8]
home=ROOT/"dev-tools/local"/tag;home.mkdir()
volume=tag+"-data";created=False
def run(args,**kw):return subprocess.run(args,text=True,capture_output=True,**kw)
config=home/"compose.json"
config.write_text(json.dumps({"services":{"probe":{"image":"mysql:8.0","entrypoint":["/bin/true"],"volumes":["data:/proof"]}},"volumes":{"data":{"external":True,"name":volume}}}))
command=["docker","compose","-p",tag,"-f",str(config)]
try:
    p=run(["docker","compose","config","--format","json"],cwd=ROOT/"dev-tools")
    assert not p.returncode
    resolved=json.loads(p.stdout)
    actual=json.loads(run(["docker","inspect","--format","{{json .Mounts}}","opencj-dev-db-1"]).stdout)
    current=next(m["Name"] for m in actual if m["Destination"]=="/var/lib/mysql")
    assert resolved["volumes"]["database"]["external"] is True
    assert resolved["volumes"]["database"]["name"]==current
    assert run(["docker","volume","inspect",volume]).returncode!=0
    assert not run(["docker","volume","create",volume]).returncode;created=True
    assert not run(command+["up","-d"]).returncode
    assert not run(command+["down","--volumes"]).returncode
    assert not run(["docker","volume","inspect",volume]).returncode
    (home/"result.json").write_text(json.dumps({"passed":True,"productionVolumeUnchanged":current,"externalProbeSurvivedDownVolumes":True},indent=2))
    print("VOLUME PASS: existing database mount unchanged; disposable external volume survives down --volumes")
finally:
    run(command+["down","--volumes"])
    if created:
        assert re.fullmatch(r"opencj-volume-safety-[0-9a-f]{8}-data",volume)
        assert not run(["docker","volume","rm",volume]).returncode
