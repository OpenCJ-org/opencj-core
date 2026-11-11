"""#200: run production CoD4 initialization before any client in an isolated server.
Checks initial systeminfo and restart behavior without configuring file hosting.
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
parser.add_argument("--cvars-revision", help="Optional Git revision for a negative baseline")
args = parser.parse_args()
tag = "download-cvars-" + uuid.uuid4().hex[:8]
home = ROOT / "dev-tools/local" / tag
mod = home / "mods/opencj"
mod.mkdir(parents=True)
# Production includes resolve unchanged; test callbacks omit account/DB startup.
for folder in ("opencj", "maps"):
    shutil.copytree(ROOT / "server-gsc" / folder, mod / folder)
if args.cvars_revision:
    source = subprocess.check_output(
        ["git", "show", args.cvars_revision + ":opencj/cvars.gsc"],
        cwd=ROOT / "server-gsc", text=True)
    (mod / "opencj/cvars.gsc").write_text(source)
for name in ("mod.ff", "z_opencj.iwd"):
    (mod / name).symlink_to("/mod-assets/" + name)
(home / "plugins").mkdir()
(home / "plugins/libcod4_1_8x.so").symlink_to(
    "/workspace/dev-tools/local/runtime/plugins/libcod4_1_8x.so")
(home / "steamclient.so").symlink_to("/game/steamclient.so")
shutil.copyfile(ROOT / "dev-tools/tests/download-cvars.gsc",
                mod / "opencj/downloadcvarstest.gsc")
(mod / "maps/mp/gametypes/cj.gsc").write_text(
    'main() { level.script = getCvar("mapname"); }\n')
(mod / "maps/mp/gametypes/_callbacksetup.gsc").write_text(
    'CodeCallback_StartGameType()\n{\n'
    '    level.downloadConnections = 0;\n'
    '    openCJ\\cvars::onInit();\n'
    '    level.downloadInitRan = true;\n'
    '    thread openCJ\\downloadCvarsTest::main();\n}\n'
    'CodeCallback_PlayerConnect() { level.downloadConnections++; }\n'
    + "\n".join("CodeCallback_" + name + "() {}" for name in
                ["PlayerDisconnect", "PlayerDamage", "PlayerKilled", "PlayerLastStand"]))
(mod / "maps/mp/mp_killhouse.gsc").write_text("main() {}\n")
name = "opencj-" + tag
cmd = ["docker", "compose", "run", "-d", "--no-deps", "--name", name, "server",
       "/workspace/cod4x-server/bin/cod4x18_dedrun"]
for key, val in [
    ("fs_basepath", "/game"), ("fs_homepath", "/workspace/dev-tools/local/" + tag),
    ("fs_game", "mods/opencj"), ("dedicated", "2"), ("net_port", "28971"),
    ("sv_maxclients", "1"), ("sv_authorizemode", "0"), ("com_hunkMegs", "1024"),
    ("developer", "1"), ("g_gametype", "cj"),
    ("cl_allowDownload", "0"), ("cl_wwwDownload", "0"),
    ("sv_allowDownload", "0"), ("sv_wwwDownload", "0"), ("sv_wwwBaseURL", ""),
]:
    cmd += ["+set", key, val]
cmd += ["+loadplugin", "libcod4_1_8x", "+map", "mp_killhouse"]
errors = ["script compile error", "script runtime error", "DOWNLOAD TEST 0:"]
try:
    subprocess.run(cmd, cwd=ROOT / "dev-tools", check=True, capture_output=True)
    log = ""
    for _ in range(40):
        time.sleep(1)
        r = subprocess.run(["docker", "logs", name], capture_output=True, text=True)
        log = r.stdout + r.stderr
        if any(e in log for e in errors) or "DOWNLOAD TEST COMPLETE" in log:
            break
    print("\n".join(l for l in log.splitlines() if "DOWNLOAD TEST" in l), flush=True)
    for error in errors[:2]:
        if error in log:
            start = log.index(error)
            print(log[start:start + 800], flush=True)
    passed = ("DOWNLOAD TEST COMPLETE failures=0" in log
              and "DOWNLOAD TEST STAGE COMPLETE 0" in log
              and not any(e in log for e in errors))
    checks = sum(l.startswith("DOWNLOAD TEST 1:") for l in log.splitlines())
    (home / "result.json").write_text(json.dumps({
        "passed": passed, "checks": checks, "cvarsRevision": args.cvars_revision,
        "coverage": "Server initialization/systeminfo before clients and after restart."
    }, indent=2) + "\n")
    assert passed, "Download-cvar regression failed; inspect " + str(home / "console.log")
    print("PASS:", checks, "checks", flush=True)
finally:
    r = subprocess.run(["docker", "logs", name], capture_output=True, text=True)
    (home / "console.log").write_text(r.stdout + r.stderr)
    subprocess.run(["docker", "rm", "-f", name], capture_output=True)
    print("Evidence:", home, flush=True)
