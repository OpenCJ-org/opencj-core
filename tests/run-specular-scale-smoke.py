"""#201: exercise map defaults/overrides and replicated codinfo in the real server.
No live clients, account/database callbacks, deployment or production map changes.
"""
from pathlib import Path
import argparse
import json
import shutil
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--binary", default="cod4x-server/bin/cod4x18_dedrun",
                    help="Binary relative to the authoritative workspace")
args = parser.parse_args()
binary = (ROOT / args.binary).resolve()
assert binary.is_file() and binary.is_relative_to(ROOT)
tag = "specular-" + uuid.uuid4().hex[:8]
home = ROOT / "dev-tools/local" / tag
mod = home / "mods/opencj"
(mod / "maps/mp/gametypes").mkdir(parents=True)
(mod / "opencj").mkdir()
for name in ("mod.ff", "z_opencj.iwd"):
    (mod / name).symlink_to("/mod-assets/" + name)
(home / "plugins").mkdir()

(home / "steamclient.so").symlink_to("/game/steamclient.so")
shutil.copyfile(ROOT / "dev-tools/tests/specular-scale.gsc",
                mod / "opencj/specularscaletest.gsc")
(mod / "maps/mp/gametypes/cj.gsc").write_text(
    'main()\n{\n    level.script = getCvar("mapname");\n'
    '    thread openCJ\\specularScaleTest::main();\n}\n')
callbacks = ["StartGameType", "PlayerConnect", "PlayerDisconnect", "PlayerDamage",
             "PlayerKilled", "PlayerLastStand"]
(mod / "maps/mp/gametypes/_callbacksetup.gsc").write_text(
    "\n".join("CodeCallback_" + name + "() {}\n" for name in callbacks))
# Real engine level scripts using the same setDvar form used by original maps.
# A cvar persists the test stage across actual map_restart/map commands.
(mod / "maps/mp/mp_killhouse.gsc").write_text(
    'main()\n{\n    if(getCvarInt("opencj_specular_test_stage") == 0)\n'
    '        setDvar("r_specularColorScale", "9");\n}\n')
(mod / "maps/mp/mp_crash.gsc").write_text(
    'main()\n{\n    setDvar("r_specularColorScale", "0.1");\n}\n')

name = "opencj-" + tag
cmd = ["docker", "compose", "run", "-d", "--no-deps", "--name", name, "server",
       "/workspace/" + str(binary.relative_to(ROOT))]
for key, value in [
    ("fs_basepath", "/game"), ("fs_homepath", "/workspace/dev-tools/local/" + tag),
    ("fs_game", "mods/opencj"), ("dedicated", "2"), ("net_port", "28971"),
    ("sv_maxclients", "1"), ("sv_authorizemode", "0"), ("com_hunkMegs", "1024"),
    ("developer", "1"), ("g_gametype", "cj"),
]:
    cmd += ["+set", key, value]
cmd += ["+map", "mp_killhouse"]
errors = ["script compile error", "script runtime error",
          "SPECULAR TEST 0:", "config string start value"]
log = ""
try:
    subprocess.run(cmd, cwd=ROOT / "dev-tools", check=True, capture_output=True)
    for _ in range(50):
        time.sleep(1)
        result = subprocess.run(["docker", "logs", name], capture_output=True, text=True)
        log = result.stdout + result.stderr
        if any(error in log for error in errors) or "SPECULAR TEST COMPLETE" in log:
            break
    for line in log.splitlines():
        if "SPECULAR TEST" in line:
            print(line, flush=True)
    passed = ("SPECULAR TEST COMPLETE failures=0" in log
              and all("SPECULAR TEST STAGE COMPLETE " + str(i) in log for i in range(3))
              and not any(error in log for error in errors))
    checks = sum(line.startswith("SPECULAR TEST 1:") for line in log.splitlines())
    (home / "result.json").write_text(json.dumps({
        "passed": passed, "checks": checks, "binary": str(binary),
        "coverage": "Real engine defaults, map/restart overrides and codinfo. "
                    "Client rendering and console rejection require a client check.",
    }, indent=2) + "\n")
    assert passed, "Engine check failed; inspect " + str(home / "console.log")
    print("PASS:", checks, "checks across four map initializations", flush=True)
finally:
    result = subprocess.run(["docker", "logs", name], capture_output=True, text=True)
    (home / "console.log").write_text(result.stdout + result.stderr)
    subprocess.run(["docker", "rm", "-f", name], capture_output=True)
    print("Evidence:", home, flush=True)
