"""Exercise real movement and lifecycle handlers with isolated account/UI services.

The fixture uses native clients on mp_to_the_moon and never connects to gameplay SQL.
Its original boost loop is retained only as a movement comparison.
"""

from pathlib import Path
import re
import uuid

from gsc_fixture import parse_options
from gsc_fixture import prepare_fixture
from gsc_fixture import run_prepared_fixture

ROOT = Path(__file__).resolve().parents[2]
TEST_MAP = "mp_to_the_moon"
COMPLETION_TIMEOUT_SECONDS = 70

# Keep the complete handlers under test; replace only their account, UI, and SQL dependencies.
RETAINED_FUNCTIONS = {
    "mapboost": None,
    "platformtest": None,
    "events/loadposition": {"main"},
    "events/spawnspectator": {"main"},
    "events/spawnplayer": {"main", "cancelPendingSpawn"},
    "events/eventhandler": {"onLoadPositionRequest"},
    "events/playerkilled": {"main"},
    "noclip": {"hasNoclip", "enableNoclip", "disableNoclip"},
    "checkpointcreation": {
        "isEditing",
        "processTravelRequests",
        "loadPosition",
        "rememberPosition",
    },
    "playerruns": {
        "restoreRun",
        "setRunIDAndInstanceNumber",
        "getRunID",
        "getRunInstanceNumber",
        "hasRunID",
        "isRunFinished",
        "_canAccessRuns",
        "_invalidatePendingCreation",
    },
    "historysave": None,
    "fpsregistration": {"finish"},
}
SERVICE_RESULTS = {
    ("login", "isLoggedIn"): "return true;",
    ("settings", "areSettingsLoaded"): "return true;",
    ("settings", "getSetting"): "return false;",
    (
        "shop",
        "loadEquipment",
    ): r"return self openCJ\platformTest::loadEquipmentForTest();",
    ("fpsregistration", "canStart"): (
        "return !isDefined(self.testRegistrationBlocked) || !self.testRegistrationBlocked;"
    ),
    ("mapid", "hasMapID"): "return true;",
    ("util", "isPlayerReady"): "return true;",
    ("noclip", "hasNoclip"): "return self.noclip;",
    ("demos", "isPlayingDemo"): "return self.playingDemo;",
    ("saveposition", "canLoadError"): "return int(self.testNoSaves);",
    ("saveposition", "incrementBackwardsCount"): "return amount;",
    ("spawnpoints", "getPlayerSpawnpoint"): "return self.testSpawn;",
    ("spawnpoints", "getSpectatorSpawnpoint"): "return self.testSpawn;",
}
SQL_READERS = ("mysqlAsyncQuery", "mysqlAsyncRead", "mysqlAsyncWrite")
HISTORY_ROWS = """
    if(isDefined(self) && isDefined(self.testHistoryFailure) && self.testHistoryFailure)
    {
        return undefined;
    }
    rows = [];
    if(isSubStr(query, "SELECT s.saveNumber"))
    {
        return rows;
    }
    row = [];
    row[0] = 1;
    row[1] = 0;
    row[2] = 0;
    row[3] = 0;
    rows[0] = row;
    return rows;
"""


def function_bodies(source):
    """Locate complete GSC bodies without treating quoted or commented braces as code."""
    mask = re.sub(
        r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"',
        lambda match: " " * len(match[0]),
        source,
    )
    definitions = list(re.finditer(r"^(\w+)\s*\(([^)]*)\)\s*\{", mask, re.MULTILINE))
    for definition in reversed(definitions):
        end = definition.end()
        depth = 1
        while depth and end < len(mask):
            if mask[end] == "{":
                depth += 1
            elif mask[end] == "}":
                depth -= 1
            end += 1
        if depth:
            raise ValueError("Unclosed GSC function: " + definition.group(1))
        yield definition.group(1), definition.group(2), definition.end(), end - 1


def service_body(module, function_name, parameters):
    """Supply fixture results with the production function's current signature."""
    first_parameter = parameters.split(",")[0].strip()
    if (module, function_name) == ("playerruns", "archiveRun"):
        return "self.testArchivedRunID = " + first_parameter + ";\n    return;"
    if (module, function_name) == ("saveposition", "getSavedPosition"):
        return "return self.testSaves[" + first_parameter + "];"
    if module == "mysql" and function_name in SQL_READERS:
        # The real loader expects a rowset, including for its storage receipt.
        return HISTORY_ROWS.replace("query,", first_parameter + ",")
    if (module, function_name) == ("saveposition", "incrementBackwardsCount"):
        return "return " + first_parameter + ";"
    return SERVICE_RESULTS.get((module, function_name), "return 0;")


def isolate_service_dependencies(mod):
    """Retain movement/lifecycle code and replace unrelated services in the private copy."""
    observed = set()
    for path in (mod / "opencj").rglob("*.gsc"):
        module = path.relative_to(mod / "opencj").with_suffix("").as_posix().lower()
        if module in RETAINED_FUNCTIONS and RETAINED_FUNCTIONS[module] is None:
            continue
        source = path.read_text()
        for function_name, parameters, start, end in function_bodies(source):
            observed.add((module, function_name))
            if function_name in RETAINED_FUNCTIONS.get(module, set()):
                continue
            body = service_body(module, function_name, parameters)
            source = source[:start] + "\n    " + body.strip() + "\n" + source[end:]
        path.write_text(source)
    required = set(SERVICE_RESULTS)
    required.update(("mysql", name) for name in SQL_READERS)
    required.update(
        {("playerruns", "archiveRun"), ("saveposition", "getSavedPosition")}
    )
    for module, functions in RETAINED_FUNCTIONS.items():
        if functions is not None:
            required.update((module, name) for name in functions)
    missing = required - observed
    if missing:
        raise RuntimeError(
            "Fixture service interfaces were not found: " + repr(sorted(missing))
        )


def select_history_scenario(mod):
    """Use fixture saves for nonempty restores; keep the real empty-run loader."""
    path = mod / "opencj/historysave.gsc"
    source = path.read_text()
    entry = re.compile(r"(?m)^historyLoad\s*\(([^)]*)\)\s*\{")
    match = entry.search(source)
    if match is None:
        raise RuntimeError("History loader was not found")
    parameter = match.group(1).strip()
    if not re.fullmatch(r"[A-Za-z_]\w*", parameter):
        raise RuntimeError("Expected one run-ID parameter in the history loader")
    source, count = entry.subn(
        lambda match: "_fixtureHistoryLoad(" + parameter + ")\n{", source
    )
    if count != 1:
        raise RuntimeError("Expected one history loader entry point")
    wrapper = (
        "\nhistoryLoad(" + parameter + ")\n{\n"
        "    if(!self.testNoSaves)\n"
        "    {\n"
        "        return true;\n"
        "    }\n"
        "    return self _fixtureHistoryLoad(" + parameter + ");\n"
        "}\n"
    )
    path.write_text(source + wrapper)


def observe_speed_changes(mod):
    """Record scale writes while still calling the native movement setter."""
    path = mod / "opencj/mapboost.gsc"
    source, count = re.subn(
        r"(?m)^([ \t]*)self\s+SetMoveSpeedScale\s*\(([^;]+)\);",
        lambda match: match[1] + "self.testScale = " + match[2] + ";\n" + match[0],
        path.read_text(),
    )
    if count == 0:
        raise RuntimeError("Native movement setters were not found")
    path.write_text(source)


def control_map_listeners(mod):
    """Let each scenario own the listener for its chosen physical boost ramp."""
    path = mod / "maps/mp/mp_to_the_moon.gsc"
    source = path.read_text()
    startup = re.compile(
        r'\bthread\s+startBoostTrigger\s*\(\s*"(svt_accelerate_[123])"\s*\)\s*;'
    )
    ramp_names = startup.findall(source)
    expected_ramps = {"svt_accelerate_1", "svt_accelerate_2", "svt_accelerate_3"}
    if len(ramp_names) != len(expected_ramps) or set(ramp_names) != expected_ramps:
        raise RuntimeError("Expected one startup listener for each of the three boost ramps")
    source = startup.sub("", source)
    source, instrumented = re.subn(
        r"(?m)^startBoostTrigger\s*\([^)]*\)\s*\{",
        lambda match: match[0] + '\n    level endon("moon_test_stop_listener");',
        source,
    )
    if instrumented != 1:
        raise RuntimeError("Expected one shared map boost listener")
    path.write_text(source)


def main():
    options = parse_options(
        default_fixture=ROOT / "dev-tools/tests/moon-boost.gsc",
        completion_marker="MOON SELFTEST COMPLETE",
        default_maps=(TEST_MAP,),
    )
    if options.maps != [TEST_MAP]:
        raise SystemExit("This fixture requires " + TEST_MAP + "'s three boost ramps.")
    home = ROOT / "dev-tools/local" / ("moon-boost-" + uuid.uuid4().hex[:8])
    source_hashes, _ = prepare_fixture(options, home, retained_callbacks=())
    mod = home / "mods/opencj"
    isolate_service_dependencies(mod)
    select_history_scenario(mod)
    observe_speed_changes(mod)
    control_map_listeners(mod)
    run_prepared_fixture(
        options,
        home,
        TEST_MAP,
        source_hashes,
        timeout_seconds=COMPLETION_TIMEOUT_SECONDS,
        extra_settings={"sv_fps": "20", "sv_maxclients": "4"},
    )


if __name__ == "__main__":
    main()
