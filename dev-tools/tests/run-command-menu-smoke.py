"""#217: exercise the command registry and menu in an isolated CoD4x server."""

from pathlib import Path
import json
import shutil
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
tag = "command-menu-" + uuid.uuid4().hex[:8]
home = ROOT / "dev-tools/local" / tag
mod = home / "mods/opencj"
mod.mkdir(parents=True)
# Production includes resolve unchanged; test callbacks omit account/DB startup.
for folder in ("opencj", "maps"):
    shutil.copytree(ROOT / "server-gsc" / folder, mod / folder)
for name in ("mod.ff", "z_opencj.iwd"):
    (mod / name).symlink_to("/mod-assets/" + name)
(home / "plugins").mkdir()

(home / "steamclient.so").symlink_to("/game/steamclient.so")
shutil.copyfile(ROOT / "dev-tools/tests/command-menu.gsc", mod / "opencj/commandmenutest.gsc")
(mod / "maps/mp/gametypes/cj.gsc").write_text('main() { level.script = getCvar("mapname"); }\n')
(mod / "maps/mp/gametypes/_callbacksetup.gsc").write_text(
    'CodeCallback_StartGameType() { thread openCJ\\commandMenuTest::main(); }\n'
    + "\n".join(
        "CodeCallback_" + name + "() {}"
        for name in [
            "PlayerConnect",
            "PlayerDisconnect",
            "PlayerDamage",
            "PlayerKilled",
            "PlayerLastStand",
        ]
    )
)
(mod / "maps/mp/mp_killhouse.gsc").write_text("main() {}\n")
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
    "/workspace/" + str(home.relative_to(ROOT)),
    "server",
    "/workspace/cod4x-server/bin/cod4x18_dedrun",
]
for key, val in [
    ("fs_basepath", "/game"),
    ("fs_homepath", "/workspace/dev-tools/local/" + tag),
    ("fs_game", "mods/opencj"),
    ("dedicated", "2"),
    ("net_port", "28971"),
    ("sv_maxclients", "1"),
    ("sv_authorizemode", "0"),
    ("com_hunkMegs", "1024"),
    ("developer", "1"),
    ("g_gametype", "cj"),
]:
    cmd += ["+set", key, val]
cmd += ["+map", "mp_killhouse"]
errors = ["script compile error", "script runtime error", "COMMAND TEST 0:"]
try:
    subprocess.run(cmd, cwd=ROOT / "dev-tools", check=True, capture_output=True)
    log = ""
    for _ in range(40):
        time.sleep(1)
        r = subprocess.run(["docker", "logs", name], capture_output=True, text=True)
        log = r.stdout + r.stderr
        if any(e in log for e in errors) or "COMMAND TEST COMPLETE" in log:
            break
    print("\n".join(l for l in log.splitlines() if "COMMAND TEST" in l), flush=True)
    for error in errors[:2]:
        if error in log:
            start = log.index(error)
            print(log[start : start + 800], flush=True)
    passed = "COMMAND TEST COMPLETE failures=0" in log and not any(e in log for e in errors)
    checks = sum(l.startswith("COMMAND TEST 1:") for l in log.splitlines())
    (home / "result.json").write_text(
        json.dumps(
            {
                "passed": passed,
                "checks": checks,
                "coverage": "Live registration, aliases, permissions, search, pages and full help text.",
            },
            indent=2,
        )
        + "\n"
    )
    assert passed, "Command-menu regression failed; inspect " + str(home / "console.log")
    print("PASS:", checks, "checks", flush=True)
finally:
    r = subprocess.run(["docker", "logs", name], capture_output=True, text=True)
    (home / "console.log").write_text(r.stdout + r.stderr)
    subprocess.run(["docker", "rm", "-f", name], capture_output=True)
    print("Evidence:", home, flush=True)
