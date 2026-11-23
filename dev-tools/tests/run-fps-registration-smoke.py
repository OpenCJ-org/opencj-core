"""Run the production startup/FPS handshake with synthetic client IO in the GSC VM."""

from pathlib import Path
import re
import uuid

from gsc_fixture import parse_options
from gsc_fixture import prepare_fixture
from gsc_fixture import run_prepared_fixture

ROOT = Path(__file__).resolve().parents[2]
REPORTED_FPS_CALL = r'\bself\s+getUserInfo\s*\(\s*"com_maxfps"\s*\)'

REGISTRATION_OBSERVERS = """
recordMessage(message)
{
    self.fpsTestMessage = message;
}

recordSpawn(atLastSavedPosition)
{
    self.fpsTestSpawns++;
}
"""
STARTUP_OBSERVERS = """
recordClientCvar(cvarName, value)
{
    self.fpsTestCvarWrites++;
}

openTestMenu()
{
    self.fpsTestAttempts++;
    if(self.fpsTestAttempts == self.fpsTestSuccessAttempt)
    {
        self thread replyToStartup();
    }
}

replyToStartup()
{
    wait self.fpsTestReplyDelaySeconds;
    if(self.fpsRegistrationRequested)
    {
        self.fpsTestReportedFPS = self.fpsTestReplyValue;
    }
    self notify("menuresponse", "opencj_client_init", "ready");
}
"""


def replace_client_io(source, replacements):
    """Observe native IO boundaries without depending on statement formatting."""
    for pattern, replacement in replacements:
        source, count = re.subn(pattern, lambda match: replacement, source)
        if count == 0:
            raise RuntimeError("Client IO boundary was not found: " + pattern)
    return source


def instrument_registration(mod):
    """Run the real registration decisions while observing messages and held spawns."""
    source = (mod / "opencj/fpsregistration.gsc").read_text()
    source = replace_client_io(
        source,
        [
            (REPORTED_FPS_CALL, "self.fpsTestReportedFPS"),
            (
                r"\bself\s+openCJ\\events\\spawnPlayer::main\s*\(",
                "self recordSpawn(",
            ),
            (r"\bself\s+iprintln(?:bold)?\s*\(", "self recordMessage("),
        ],
    )
    (mod / "opencj/fpsregistrationtestdouble.gsc").write_text(
        source + "\n" + REGISTRATION_OBSERVERS
    )


def instrument_startup(mod):
    """Keep the real polling/retry loop and supply deterministic client acknowledgements."""
    source = (mod / "opencj/clientinit.gsc").read_text()
    source = replace_client_io(
        source,
        [
            (REPORTED_FPS_CALL, "self.fpsTestReportedFPS"),
            (
                r'\bself\s+openMenu\s*\(\s*"opencj_client_init"\s*\)',
                "self openTestMenu()",
            ),
            (r"\bself\s+setClientCvar\s*\(", "self recordClientCvar("),
            (r"\bfpsRegistration::", "fpsRegistrationTestDouble::"),
        ],
    )
    (mod / "opencj/clientinittestdouble.gsc").write_text(
        source + "\n" + STARTUP_OBSERVERS
    )


def main():
    options = parse_options(
        default_fixture=ROOT / "dev-tools/tests/fps-registration.gsc",
        completion_marker="FPS REGISTRATION COMPLETE",
    )
    for map_name in options.maps:
        home = ROOT / "dev-tools/local" / ("fpsregistration-" + uuid.uuid4().hex[:8])
        source_hashes, _ = prepare_fixture(options, home, retained_callbacks=())
        mod = home / "mods/opencj"
        instrument_registration(mod)
        instrument_startup(mod)
        fixture = mod / "opencj/platformtest.gsc"
        fixture.write_text(
            replace_client_io(
                fixture.read_text(),
                [
                    (r"\bfpsRegistration::", "fpsRegistrationTestDouble::"),
                    (r"\bclientInit::", "clientInitTestDouble::"),
                ],
            )
        )
        run_prepared_fixture(options, home, map_name, source_hashes)


if __name__ == "__main__":
    main()
