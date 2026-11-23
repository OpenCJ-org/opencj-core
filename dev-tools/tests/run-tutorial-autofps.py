"""Run the tutorial auto-FPS rule test inside an isolated CoD4 server.

Builds dev-tools/tests/tutorial-autofps-engine.cpp as a plugin, starts a
throwaway server (no published ports, database or players) with the given
engine binary, and waits for the test's completion line. The binary must be
built from a checkout that includes server-ext/opencj_autofps.cpp.
Output stays in ignored dev-tools/local/.
"""

import argparse
import re
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path

from compose_environment import workspace_path

ROOT = Path(__file__).resolve().parents[2]
CONTAINER_ROOT = "/workspace"
TEST_SOURCE = "dev-tools/tests/tutorial-autofps-engine.cpp"
PLUGIN_NAME = "tutorial_autofps_test"
COMPLETION_MARKER = "TUTORIAL AUTOFPS COMPLETE"
MAX_WAIT_SECONDS = 120


def container_path(path):
    return CONTAINER_ROOT + "/" + path.relative_to(ROOT).as_posix()


def build_plugin(output_dir):
    """Compile the test plugin in the build container; exit on failure."""
    plugin_path = output_dir / f"{PLUGIN_NAME}.so"
    build = subprocess.run(
        [
            "docker",
            "compose",
            "run",
            "--rm",
            "--no-deps",
            "build",
            "g++",
            "-m32",
            "-std=c++11",
            "-msse2",
            "-mfpmath=sse",
            "-fPIC",
            "-shared",
            "-DCOD4",
            f"{CONTAINER_ROOT}/{TEST_SOURCE}",
            "-o",
            container_path(plugin_path),
        ],
        cwd=ROOT / "dev-tools",
        capture_output=True,
        text=True,
    )
    (output_dir / "build.log").write_text(build.stdout + build.stderr)
    if build.returncode != 0:
        print((build.stdout + build.stderr)[-8000:])
        sys.exit(build.returncode)
    return plugin_path


def empty_script_callbacks(callback_path):
    """Empty engine callbacks so nothing reaches account or database code."""
    source = re.sub(r"//[^\n]*", "", callback_path.read_text())
    matches = list(re.finditer(r"(CodeCallback_\w+)\([^)]*\)\s*\{", source))
    for match in reversed(matches):
        body_end = match.end()
        depth = 1
        while depth:
            if source[body_end] == "{":
                depth += 1
            elif source[body_end] == "}":
                depth -= 1
            body_end += 1
        source = source[: match.end()] + "\n" + source[body_end - 1 :]
    callback_path.write_text(source)


def prepare_home(home, plugin_path):
    """Create an isolated fs_homepath with a copy of the current scripts."""
    mod = home / "mods/opencj"
    mod.mkdir(parents=True)
    for name in ["opencj", "maps"]:
        shutil.copytree(ROOT / "server-gsc" / name, mod / name)
    for name in ["mod.ff", "z_opencj.iwd"]:
        (mod / name).symlink_to("/mod-assets/" + name)
    (home / "usermaps").symlink_to("/game/usermaps")
    (home / "steamclient.so").symlink_to("/game/steamclient.so")
    (home / "plugins").mkdir()
    (home / f"plugins/{PLUGIN_NAME}.so").symlink_to(container_path(plugin_path))

    init_path = mod / "opencj/events/init.gsc"
    # A return at the top still precaches every referenced gameplay function.
    # This private copy needs no gameplay initialization at all.
    init_path.write_text("main()\n{\n}\n")
    empty_script_callbacks(mod / "maps/mp/gametypes/_callbacksetup.gsc")


def run_server(home, map_name, binary):
    """Start the throwaway server, wait for the test, remove it, return its log."""
    container_name = "opencj-" + home.name
    arguments = [
        "docker",
        "compose",
        "run",
        "-d",
        "--no-deps",
        "--name",
        container_name,
        "--workdir",
        container_path(home),
        "server",
        binary,
    ]
    settings = [
        ("fs_basepath", "/game"),
        ("fs_homepath", container_path(home)),
        ("fs_game", "mods/opencj"),
        ("dedicated", "2"),
        ("net_port", "28968"),
        ("sv_maxclients", "2"),
        ("sv_authorizemode", "0"),
        ("com_hunkMegs", "1024"),
        ("g_gametype", "cj"),
    ]
    for name, value in settings:
        arguments += ["+set", name, value]
    arguments += ["+loadplugin", PLUGIN_NAME, "+map", map_name]

    log = ""
    try:
        subprocess.run(
            arguments, cwd=ROOT / "dev-tools", check=True, capture_output=True
        )
        for _ in range(MAX_WAIT_SECONDS):
            time.sleep(1)
            log = subprocess.check_output(
                ["docker", "logs", container_name], stderr=subprocess.STDOUT, text=True
            )
            failed = any(
                marker in log.lower()
                for marker in (
                    "script compile error",
                    "script runtime error",
                    "max_precache_entries exceeded",
                )
            )
            if COMPLETION_MARKER in log or failed:
                break
    finally:
        subprocess.run(["docker", "rm", "-f", container_name], capture_output=True)
    return log


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "binary",
        help="Engine inside this checkout; host paths and /workspace/... paths are accepted",
    )
    parser.add_argument("--map", default="mp_killhouse")
    options = parser.parse_args()
    binary_path = options.binary
    if binary_path.startswith(CONTAINER_ROOT + "/"):
        binary_path = ROOT / binary_path.removeprefix(CONTAINER_ROOT + "/")
    try:
        binary = workspace_path(binary_path)
    except ValueError as error:
        parser.error(str(error))

    home = ROOT / "dev-tools/local" / ("tutorial-autofps-" + uuid.uuid4().hex[:8])
    home.mkdir(parents=True)
    plugin_path = build_plugin(home)
    prepare_home(home, plugin_path)
    log = run_server(home, options.map, binary)
    (home / "console.log").write_text(log)

    for line in log.splitlines():
        if "TUTORIAL AUTOFPS" in line:
            print(line)
    print("Log: " + str(home / "console.log"))
    has_script_error = any(
        marker in log.lower()
        for marker in ("script compile error", "script runtime error")
    )
    if f"{COMPLETION_MARKER} failures=0" not in log or has_script_error:
        sys.exit(1)


if __name__ == "__main__":
    main()
