"""Compile production GSC and test its registration state machine with mocked client IO.
No client connection, database initialization, live reload, or config secrets.
Run from the server: python3 dev-tools/tests/run-fps-registration-smoke.py
"""
from pathlib import Path
import shutil
import subprocess
import time
import uuid

root = Path(__file__).resolve().parents[2]
tag = "fpsregistration-" + uuid.uuid4().hex[:8]
smoke = root / "dev-tools/local" / tag
mod = smoke / "mods/opencj"
mod.mkdir(parents=True)
for name in ("opencj", "maps"):
    shutil.copytree(root / "server-gsc" / name, mod / name)
for name in ("mod.ff", "z_opencj.iwd"):
    (mod / name).symlink_to("/mod-assets/" + name)
(smoke / "plugins").mkdir()
(smoke / "plugins/libcod4_1_8x.so").symlink_to("/workspace/dev-tools/local/runtime/plugins/libcod4_1_8x.so")
(smoke / "steamclient.so").symlink_to("/game/steamclient.so")
bs = chr(92)
def g(s):
    return s.replace("@", bs)

# Keep the real helper in the copy: all production call sites compile against it.
# A separate test double replaces only client IO; waits, branches, and predicates
# are copied directly from the production implementation.
helper = (mod / "opencj/fpsregistration.gsc").read_text()
replacements = [
    ('self getUserInfo("com_maxfps")', "self.fpsTestReportedFPS"),
    (g("self openCJ@menus::openFPSUserinfoMenu();"), "self testOpen();"),
    ("self closeMenu();", "self.fpsTestCloses++;"),
    (g("self openCJ@events@spawnPlayer::main(self.fpsRegistrationSpawnAtSave);"), "self.fpsTestSpawns++;"),
    ("self iprintln(", "self testMessage("),
    ("self iprintlnbold(", "self testMessage("),
]
for old, new in replacements:
    assert old in helper, old
    helper = helper.replace(old, new)
helper += """
testOpen()
{
    self.fpsTestAttempts++;
    if (self.fpsTestAttempts == self.fpsTestSuccessAttempt)
    {
        if (isDefined(self.fpsTestRestoreDelay))
        {
            self.fpsTestReportedFPS = "999";
            if (self.fpsTestRestoreDelay >= 0)
                self thread testRestore();
        }
        else
            self.fpsTestReportedFPS = "333";
    }
}
testRestore()
{
    wait self.fpsTestRestoreDelay;
    self.fpsTestReportedFPS = "333";
}
testMessage(message)
{
    self.fpsTestMessage = message;
}
"""
(mod / "opencj/fpsregistrationtestdouble.gsc").write_text(helper)
tests = (root / "dev-tools/tests/fps-registration.gsc").read_text()
(mod / "opencj/fpsregistrationtest.gsc").write_text(tests.replace("fpsRegistration::", "fpsRegistrationTestDouble::"))
p = mod / "opencj/events/init.gsc"
s = p.read_text()
assert "    level.playerCount = 0;" in s
p.write_text(s.replace("    level.playerCount = 0;", "    return;" + chr(10) + "    level.playerCount = 0;", 1))
p = mod / "maps/mp/gametypes/cj.gsc"
s = p.read_text()
needle = "main()" + chr(10) + "{"
assert needle in s
p.write_text(s.replace(needle, needle + chr(10) + g("    thread openCJ@fpsRegistrationTest::main();"), 1))
container = "opencj-" + tag
args = [
    "docker", "compose", "run", "-d", "--no-deps", "--name", container, "server",
    "/workspace/cod4x-server/bin/cod4x18_dedrun",
    "+set", "fs_basepath", "/game",
    "+set", "fs_homepath", "/workspace/dev-tools/local/" + tag,
    "+set", "fs_game", "mods/opencj", "+set", "dedicated", "2",
    "+set", "net_port", "28963", "+set", "sv_maxclients", "1",
    "+set", "sv_authorizemode", "0", "+set", "com_hunkMegs", "1024",
    "+set", "developer", "1", "+set", "g_gametype", "cj",
    "+set", "g_log", "fpsregistration-test.log", "+set", "g_logSync", "1",
    "+loadplugin", "libcod4_1_8x", "+map", "mp_dark",
]
try:
    subprocess.run(args, cwd=root / "dev-tools", check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    logfile = mod / "fpsregistration-test.log"
    for _ in range(25):
        time.sleep(1)
        text = logfile.read_text(errors="replace") if logfile.exists() else ""
        if "[FPSREG_TEST] FAIL" in text:
            raise RuntimeError("FPS registration assertion failed: " + str(logfile))
        if "[FPSREG_TEST] PASS all assertions" in text:
            print("PASS: production scripts compiled; registration retry, gate, recovery, message, and classification assertions passed.")
            break
    else:
        raise RuntimeError("Smoke test did not pass; inspect isolated container logs and " + str(logfile))
finally:
    subprocess.run(["docker", "rm", "-f", container], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
