"""Database-free allocation audit on an isolated engine; never restart live OpenCJ."""

from pathlib import Path
import json
import shutil
import subprocess
import time
import uuid
import hashlib
import re

root = Path(__file__).resolve().parents[2]
binary = root / "cod4x-server/bin/cod4x18_dedrun"
source_files = (
    "server-gsc/opencj/demos.gsc",
    "server-gsc/opencj/events/playerconnect.gsc",
    "server-gsc/opencj/huds/hudspeedometer.gsc",
    "server-ext/opencj_demo.cpp",
)
before = {rel: hashlib.sha256((root / rel).read_bytes()).hexdigest() for rel in source_files}
binary_hash = hashlib.sha256(binary.read_bytes()).hexdigest()
tag = "player-memory-" + uuid.uuid4().hex[:8]
home = root / "dev-tools/local" / tag
mod = home / "mods/opencj"
mod.mkdir(parents=True)


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


for name in ("opencj", "maps"):
    shutil.copytree(root / "server-gsc" / name, mod / name)
for name in ("mod.ff", "z_opencj.iwd"):
    (mod / name).symlink_to("/mod-assets/" + name)
(home / "plugins").mkdir()
(home / "steamclient.so").symlink_to("/game/steamclient.so")

shutil.copyfile(root / "dev-tools/tests/player-memory-audit.gsc", mod / "opencj/memoryaudit.gsc")
(mod / "maps/mp/gametypes/cj.gsc").write_text('main(){level.script=getCvar("mapname");}\n')
(mod / "maps/mp/gametypes/_callbacksetup.gsc").write_text(
    'CodeCallback_StartGameType(){thread openCJ\\memoryAudit::main();}\n'
    + "\n".join(
        "CodeCallback_" + c + "(){}"
        for c in (
            "PlayerConnect",
            "PlayerDisconnect",
            "PlayerDamage",
            "PlayerKilled",
            "PlayerLastStand",
        )
    )
)
(mod / "maps/mp/mp_killhouse.gsc").write_text("main(){}\n")
relative = str(home.relative_to(root))
p = run(
    [
        "docker",
        "compose",
        "run",
        "--rm",
        "--no-deps",
        "build",
        "bash",
        "-lc",
        "g++ -m32 -std=c++11 -fPIC -shared -DCOD4 /workspace/dev-tools/tests/player-memory-audit.cpp -o /workspace/"
        + relative
        + "/plugins/memory_audit.so",
    ],
    cwd=root / "dev-tools",
    timeout=90,
)
(home / "build.log").write_text(p.stdout + p.stderr)
if p.returncode:
    print(p.stdout + p.stderr)
    raise SystemExit(p.returncode)
name = "opencj-" + tag
cmd = [
    "docker",
    "compose",
    "run",
    "-d",
    "--no-deps",
    "--name",
    name,
    "--workdir",
    "/workspace/" + str(home.relative_to(root)),
    "server",
    "/workspace/cod4x-server/bin/cod4x18_dedrun",
]
for k, v in [
    ("fs_basepath", "/game"),
    ("fs_homepath", "/workspace/" + relative),
    ("fs_game", "mods/opencj"),
    ("dedicated", 2),
    ("net_port", 28976),
    ("sv_maxclients", 2),
    ("sv_authorizemode", 0),
    ("com_hunkMegs", 1024),
    ("developer", 1),
    ("g_gametype", "cj"),
]:
    cmd += ["+set", k, str(v)]
cmd += ["+loadplugin", "memory_audit", "+map", "mp_killhouse"]
try:
    p = run(cmd, cwd=root / "dev-tools")
    assert p.returncode == 0, p.stderr
    for _ in range(40):
        time.sleep(1)
        p = run(["docker", "logs", name])
        log = p.stdout + p.stderr
        if any(
            x in log
            for x in (
                "MEM COMPLETE",
                "script compile error",
                "script runtime error",
                "Received signal:",
            )
        ):
            break
    lines = [l for l in log.splitlines() if l.startswith("MEM ")]
    print("\n".join(lines), flush=True)
    if "MEM COMPLETE" not in log:
        print(log[-5000:])
        raise SystemExit(1)
    metrics = {}
    for line in lines:
        m = re.match(r"MEM (\w+) (.*)", line)
        if m:
            metrics[m[1]] = {k: int(v) for k, v in re.findall(r"(\w+)=(\d+)", m[2])}
    assert (
        metrics["cache_512_unchanged"]["reachableChildren"]
        - metrics["cache_empty"]["reachableChildren"]
        == 0
    )
    assert (
        metrics["cache_512_unchanged"]["reachableObjects"]
        - metrics["cache_empty"]["reachableObjects"]
        == 0
    )
    assert (
        metrics["cache_cleared"]["reachableChildren"] == metrics["cache_empty"]["reachableChildren"]
    )
    assert metrics["speed_duplicate"]["huds"] - metrics["progress"]["huds"] == 0
    assert metrics["NATIVE"]["changes"] == 1 and metrics["NATIVE"]["samples"] == 512
    assert metrics["position_enabled"]["huds"] - metrics["connect_huds"]["huds"] == 4
    assert metrics["position_disabled"]["huds"] == metrics["connect_huds"]["huds"]
    assert before == {
        rel: hashlib.sha256((root / rel).read_bytes()).hexdigest() for rel in source_files
    }
    assert binary_hash == hashlib.sha256(binary.read_bytes()).hexdigest()
    (home / "result.json").write_text(
        json.dumps(
            {
                "measurements": metrics,
                "checksPassed": 9,
                "sourceHashes": before,
                "binarySha256": binary_hash,
                "productionUnchanged": True,
                "databaseAccess": False,
                "liveRestart": False,
            },
            indent=2,
        )
        + "\n"
    )
finally:
    p = run(["docker", "logs", name])
    (home / "console.log").write_text(p.stdout + p.stderr)
    run(["docker", "rm", "-f", name])
    print("Audit evidence: " + str(home), flush=True)
