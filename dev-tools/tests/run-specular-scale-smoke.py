"""Exercise map specular defaults and replicated values in an isolated server.

Uses real map changes without live clients, accounts or database callbacks.
"""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
from textwrap import dedent
import time
import uuid

from compose_environment import workspace_file, workspace_path

ROOT = Path(__file__).resolve().parents[2]
COMPLETION_TIMEOUT_SECONDS = 50
LOG_POLL_SECONDS = 1
DOCKER_COMMAND_TIMEOUT_SECONDS = 30
SCRIPT_ERRORS = (
    "script compile error",
    "script runtime error",
    "SPECULAR TEST 0:",
    "config string start value",
)


def parse_options():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--binary",
        default="cod4x-server/bin/cod4x18_dedrun",
        help="Engine path inside this core checkout",
    )
    options = parser.parse_args()
    binary_input = options.binary
    if binary_input.startswith("/workspace/"):
        binary_input = ROOT / binary_input.removeprefix("/workspace/")
    try:
        options.binary = workspace_file(ROOT / binary_input)
    except ValueError as error:
        parser.error(str(error))
    return options


def prepare_fixture(home):
    """Build the minimal scripts needed for four real map initializations."""
    mod = home / "mods/opencj"
    gametypes = mod / "maps/mp/gametypes"
    gametypes.mkdir(parents=True)
    (mod / "opencj").mkdir()
    (home / "plugins").mkdir()
    for name in ("mod.ff", "z_opencj.iwd"):
        (mod / name).symlink_to("/mod-assets/" + name)
    (home / "steamclient.so").symlink_to("/game/steamclient.so")
    shutil.copyfile(
        ROOT / "dev-tools/tests/specular-scale.gsc",
        mod / "opencj/specularscaletest.gsc",
    )
    (gametypes / "cj.gsc").write_text(dedent(r"""
        main()
        {
            level.script = getCvar("mapname");
            thread openCJ\specularScaleTest::main();
        }
    """).lstrip())
    callbacks = (
        "StartGameType",
        "PlayerConnect",
        "PlayerDisconnect",
        "PlayerDamage",
        "PlayerKilled",
        "PlayerLastStand",
    )
    (gametypes / "_callbacksetup.gsc").write_text(
        "\n".join("CodeCallback_" + name + "()\n{\n}\n" for name in callbacks)
    )
    # A cvar retains the scenario stage across actual map_restart/map commands.
    (mod / "maps/mp/mp_killhouse.gsc").write_text(dedent("""
        main()
        {
            if(getCvarInt("opencj_specular_test_stage") == 0)
            {
                setDvar("r_specularColorScale", "9");
            }
        }
    """).lstrip())
    (mod / "maps/mp/mp_crash.gsc").write_text(dedent("""
        main()
        {
            setDvar("r_specularColorScale", "0.1");
        }
    """).lstrip())


def server_command(binary, home, container_name):
    container_home = "/workspace/" + home.relative_to(ROOT).as_posix()
    command = [
        "docker",
        "compose",
        "run",
        "-d",
        "--no-deps",
        "--name",
        container_name,
        "--workdir",
        container_home,
        "server",
        workspace_path(binary),
    ]
    for name, value in (
        ("fs_basepath", "/game"),
        ("fs_homepath", container_home),
        ("fs_game", "mods/opencj"),
        ("dedicated", "2"),
        ("net_port", "28971"),
        ("sv_maxclients", "1"),
        ("sv_authorizemode", "0"),
        ("com_hunkMegs", "1024"),
        ("developer", "1"),
        ("g_gametype", "cj"),
    ):
        command.extend(("+set", name, value))
    command.extend(("+map", "mp_killhouse"))
    return command


def wait_for_completion(container_name):
    deadline = time.monotonic() + COMPLETION_TIMEOUT_SECONDS
    log = ""
    while time.monotonic() < deadline:
        time.sleep(LOG_POLL_SECONDS)
        result = subprocess.run(
            ["docker", "logs", container_name],
            capture_output=True,
            text=True,
            check=True,
            timeout=DOCKER_COMMAND_TIMEOUT_SECONDS,
        )
        log = result.stdout + result.stderr
        failed = any(error in log for error in SCRIPT_ERRORS)
        if failed or "SPECULAR TEST COMPLETE" in log:
            break
    return log


def record_result(home, binary, log):
    """Require every map stage and at least one executed check, not just startup."""
    for line in log.splitlines():
        if "SPECULAR TEST" in line:
            print(line, flush=True)
    passed = (
        "SPECULAR TEST COMPLETE failures=0" in log
        and all(
            "SPECULAR TEST STAGE COMPLETE " + str(stage) in log for stage in range(3)
        )
        and not any(error in log for error in SCRIPT_ERRORS)
    )
    checks = sum(line.startswith("SPECULAR TEST 1:") for line in log.splitlines())
    passed = passed and checks > 0
    result = {
        "passed": passed,
        "checks": checks,
        "binary": str(binary),
        "binarySha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "fixtureSha256": hashlib.sha256(
            (home / "mods/opencj/opencj/specularscaletest.gsc").read_bytes()
        ).hexdigest(),
        "coverage": "Real engine defaults, map/restart overrides and codinfo. "
        "Client rendering and console rejection require a client check.",
    }
    (home / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    if not passed:
        raise RuntimeError("Engine check failed; inspect " + str(home / "console.log"))
    print("PASS:", checks, "checks across four map initializations", flush=True)


def main():
    options = parse_options()
    tag = "specular-" + uuid.uuid4().hex[:8]
    home = ROOT / "dev-tools/local" / tag
    prepare_fixture(home)
    container_name = "opencj-" + tag
    try:
        subprocess.run(
            server_command(options.binary, home, container_name),
            cwd=ROOT / "dev-tools",
            check=True,
            capture_output=True,
            timeout=DOCKER_COMMAND_TIMEOUT_SECONDS,
        )
        log = wait_for_completion(container_name)
        record_result(home, options.binary, log)
    finally:
        # Even a failed log read must release the uniquely named test container.
        try:
            result = subprocess.run(
                ["docker", "logs", container_name],
                capture_output=True,
                text=True,
                timeout=DOCKER_COMMAND_TIMEOUT_SECONDS,
            )
            (home / "console.log").write_text(result.stdout + result.stderr)
        finally:
            subprocess.run(
                ["docker", "rm", "-f", container_name],
                capture_output=True,
                timeout=DOCKER_COMMAND_TIMEOUT_SECONDS,
            )
            print("Evidence:", home, flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
