"""Exercise actual mp_blue2 finish handlers without clients or database writes."""
from pathlib import Path
import shutil, subprocess, time, uuid
root = Path(__file__).resolve().parents[2]
dev = root / "dev-tools"
tag = "blue2-finish-" + uuid.uuid4().hex[:8]
smoke = dev / "local" / tag
mod = smoke / "mods/opencj"
mod.mkdir(parents=True)
for name in ("opencj", "maps"):
    shutil.copytree(root / "server-gsc" / name, mod / name)
for name in ("mod.ff", "z_opencj.iwd"):
    (mod / name).symlink_to("/mod-assets/" + name)
(smoke / "plugins").mkdir()
(smoke / "plugins/libcod4_1_8x.so").symlink_to("/workspace/dev-tools/local/runtime/plugins/libcod4_1_8x.so")
(smoke / "steamclient.so").symlink_to("/game/steamclient.so")
p = mod / "opencj/events/init.gsc"
s = p.read_text()
assert "    level.playerCount = 0;" in s
p.write_text(s.replace("    level.playerCount = 0;", "    return;\n    level.playerCount = 0;", 1))
shutil.copyfile(dev / "tests/blue2-finish.gsc", mod / "opencj/blue2test.gsc")
p = mod / "maps/mp/gametypes/cj.gsc"
s = p.read_text()
assert "main()\n{" in s
p.write_text(s.replace("main()\n{", "main()\n{\n    thread openCJ" + chr(92) + "blue2test::main();", 1))
container = "opencj-" + tag
args = ["docker", "compose", "run", "-d", "--no-deps", "--name", container, "server",
        "/workspace/cod4x-server/bin/cod4x18_dedrun", "+set", "fs_basepath", "/game",
        "+set", "fs_homepath", "/workspace/dev-tools/local/" + tag,
        "+set", "fs_game", "mods/opencj", "+set", "dedicated", "2", "+set", "net_port", "28964",
        "+set", "sv_maxclients", "1", "+set", "sv_authorizemode", "0",
        "+set", "com_hunkMegs", "1024", "+set", "developer", "1", "+set", "g_gametype", "cj",
        "+set", "g_log", "blue2-test.log", "+set", "g_logSync", "1",
        "+loadplugin", "libcod4_1_8x", "+map", "mp_blue2"]
try:
    subprocess.run(args, cwd=dev, check=True, capture_output=True)
    logfile = mod / "blue2-test.log"
    for _ in range(25):
        time.sleep(1)
        text = logfile.read_text() if logfile.exists() else ""
        if "[BLUE2_TEST] FAIL" in text:
            raise RuntimeError(text)
        if "[BLUE2_TEST] PASS" in text:
            print("PASS: actual Easy, Intermediate, Hard handlers; first and repeated trigger")
            break
    else:
        raise RuntimeError("No test result; inspect " + str(smoke))
finally:
    logs = subprocess.run(["docker", "logs", container], capture_output=True, text=True)
    (smoke / "console.log").write_text(logs.stdout + logs.stderr)
    subprocess.run(["docker", "rm", "-f", container], capture_output=True)
