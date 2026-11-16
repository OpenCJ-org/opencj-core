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

(smoke / "steamclient.so").symlink_to("/game/steamclient.so")
bs = chr(92)


def g(s):
    return s.replace("@", bs)


# Compile the production call sites unchanged. Copies replace only client IO;
# the coordinator's waits, retries, acknowledgement listener, and FPS gates run
# inside the real GSC VM, with no live client or database.
def replace_io(source, replacements):
    for old, new in replacements:
        assert old in source, old
        source = source.replace(old, new)
    return source


helper = (mod / "opencj/fpsregistration.gsc").read_text()
helper = replace_io(
    helper,
    [
        ('self getUserInfo("com_maxfps")', "self.fpsTestReportedFPS"),
        (
            g("self openCJ@events@spawnPlayer::main(self.fpsRegistrationSpawnAtSave);"),
            "self.fpsTestSpawns++;",
        ),
        ("self iprintln(", "self testMessage("),
        ("self iprintlnbold(", "self testMessage("),
    ],
)
helper += """
testMessage(message)
{
    self.fpsTestMessage = message;
}
"""
(mod / "opencj/fpsregistrationtestdouble.gsc").write_text(helper)
startup = (mod / "opencj/clientinit.gsc").read_text()
assert "closeMenu(" not in startup, "A server close would cancel deferred setup"
startup = replace_io(
    startup,
    [
        ('self getUserInfo("com_maxfps")', "self.fpsTestReportedFPS"),
        ('self openMenu("opencj_client_init");', "self testOpen();"),
        ("self setClientCvar(", "self testCvar("),
        ("fpsRegistration::", "fpsRegistrationTestDouble::"),
    ],
)
startup += """
testCvar(name, value)
{
    self.fpsTestCvarWrites++;
}
testOpen()
{
    self.fpsTestAttempts++;
    if (self.fpsTestAttempts == self.fpsTestSuccessAttempt)
        self thread testReply();
}
testReply()
{
    wait self.fpsTestReplyDelay;
    if (self.fpsRegistrationRequested)
        self.fpsTestReportedFPS = self.fpsTestReplyValue;
    self notify("menuresponse", "opencj_client_init", "ready");
}
"""
(mod / "opencj/clientinittestdouble.gsc").write_text(startup)
tests = (root / "dev-tools/tests/fps-registration.gsc").read_text()
tests = tests.replace("fpsRegistration::", "fpsRegistrationTestDouble::")
tests = tests.replace("clientInit::", "clientInitTestDouble::")
(mod / "opencj/fpsregistrationtest.gsc").write_text(tests)
p = mod / "opencj/events/init.gsc"
s = p.read_text()
assert "    level.playerCount = 0;" in s
p.write_text(
    s.replace(
        "    level.playerCount = 0;", "    return;" + chr(10) + "    level.playerCount = 0;", 1
    )
)
p = mod / "maps/mp/gametypes/cj.gsc"
s = p.read_text()
needle = "main()" + chr(10) + "{"
assert needle in s
p.write_text(
    s.replace(needle, needle + chr(10) + g("    thread openCJ@fpsRegistrationTest::main();"), 1)
)
container = "opencj-" + tag
args = [
    "docker",
    "compose",
    "run",
    "-d",
    "--no-deps",
    "--name",
    container,
    "--workdir",
    "/workspace/" + str(smoke.relative_to(root)),
    "server",
    "/workspace/cod4x-server/bin/cod4x18_dedrun",
    "+set",
    "fs_basepath",
    "/game",
    "+set",
    "fs_homepath",
    "/workspace/dev-tools/local/" + tag,
    "+set",
    "fs_game",
    "mods/opencj",
    "+set",
    "dedicated",
    "2",
    "+set",
    "net_port",
    "28963",
    "+set",
    "sv_maxclients",
    "1",
    "+set",
    "sv_authorizemode",
    "0",
    "+set",
    "com_hunkMegs",
    "1024",
    "+set",
    "developer",
    "1",
    "+set",
    "g_gametype",
    "cj",
    "+set",
    "g_log",
    "fpsregistration-test.log",
    "+set",
    "g_logSync",
    "1",
    "+map",
    "mp_dark",
]
try:
    subprocess.run(
        args, cwd=root / "dev-tools", check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    logfile = mod / "fpsregistration-test.log"
    for _ in range(40):
        time.sleep(1)
        text = logfile.read_text(errors="replace") if logfile.exists() else ""
        if "[FPSREG_TEST] FAIL" in text:
            raise RuntimeError("FPS registration assertion failed: " + str(logfile))
        if "[FPSREG_TEST] PASS all assertions" in text:
            print(
                "PASS: production scripts compiled; combined startup, retry, acknowledgement, FPS gate, recovery, and classification assertions passed."
            )
            break
    else:
        raise RuntimeError(
            "Smoke test did not pass; inspect isolated container logs and " + str(logfile)
        )
finally:
    subprocess.run(
        ["docker", "rm", "-f", container], stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
