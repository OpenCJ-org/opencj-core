"""Run a GSC fixture in an isolated server with no gameplay database callbacks."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import time
import uuid

from compose_environment import workspace_file, workspace_path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT_FOLDERS = ("opencj", "maps")
SCRIPT_ERRORS = ("script compile error", "script runtime error")
COMPLETION_TIMEOUT_SECONDS = 45


def parse_options():
    """Reject invalid inputs before creating a fixture home or container."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("maps", nargs="*", default=["mp_killhouse"])
    parser.add_argument(
        "--binary", default="/workspace/cod4x-server/bin/cod4x18_dedrun"
    )
    parser.add_argument(
        "--fixture", type=Path, default=ROOT / "dev-tools/tests/demo-viewing-24.gsc"
    )
    parser.add_argument(
        "--scripts",
        type=Path,
        default=ROOT / "server-gsc",
        help="Exact deployed-script artifact to exercise",
    )
    parser.add_argument("--completion-marker", default="DEMO VIEWING COMPLETE")
    parser.add_argument(
        "--baseline",
        action="store_true",
        help="Use the current HEAD's tracked GSC scripts in the isolated copy",
    )
    options = parser.parse_args()
    binary_input = options.binary
    if binary_input.startswith("/workspace/"):
        binary_input = ROOT / binary_input.removeprefix("/workspace/")
    try:
        options.engine = workspace_file(binary_input)
        options.binary = workspace_path(options.engine)
    except ValueError as error:
        parser.error(str(error))
    options.fixture = options.fixture.resolve()
    options.scripts = options.scripts.resolve()
    if not options.fixture.is_file() or options.fixture.suffix.lower() != ".gsc":
        parser.error("--fixture must be an existing GSC file")
    for folder in SCRIPT_FOLDERS:
        if not (options.scripts / folder).is_dir():
            parser.error("--scripts must contain opencj and maps directories")
    if not options.completion_marker.strip() or "\n" in options.completion_marker:
        parser.error("--completion-marker must be one nonempty line")
    for map_name in options.maps:
        if not re.fullmatch(r"[A-Za-z0-9_-]+", map_name):
            parser.error(
                "Map names must contain only letters, numbers, underscores or hyphens"
            )
    return options


def script_hashes(mod):
    return {
        path.relative_to(mod).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
        for folder in SCRIPT_FOLDERS
        for path in (mod / folder).rglob("*.gsc")
    }


def copy_scripts(options, mod):
    """Copy the selected release; an explicit baseline replaces only its GSC sources."""
    for folder in SCRIPT_FOLDERS:
        shutil.copytree(options.scripts / folder, mod / folder)
    if not options.baseline:
        return
    for folder in SCRIPT_FOLDERS:
        for path in (mod / folder).rglob("*.gsc"):
            path.unlink()
    tracked = subprocess.check_output(
        [
            "git",
            "ls-tree",
            "-r",
            "--name-only",
            "HEAD",
            "server-gsc/opencj",
            "server-gsc/maps",
        ],
        cwd=ROOT,
        text=True,
    ).splitlines()
    for source_name in tracked:
        source_path = Path(source_name)
        if source_path.suffix.lower() != ".gsc":
            continue
        target = mod / source_path.relative_to("server-gsc")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(
            subprocess.check_output(["git", "show", "HEAD:" + source_name], cwd=ROOT)
        )


def install_observation_hooks(mod, fixture_name):
    """Forward selected native HUD calls through fixture observers in the private copy."""
    hooks = {
        "hud-display.gsc": (
            "opencj/huds/hudfps.gsc",
            (
                (
                    r"\bself\s+setClientCvar\s*\(",
                    r"self openCJ\platformTest::recordClientCvar(",
                ),
            ),
        ),
        "hud-settings.gsc": (
            "opencj/checkpointpointers.gsc",
            (
                (r"\bsetWaypoint\s*\(", r"openCJ\platformTest::waypoint("),
                (r"\bsetShader\s*\(", r"openCJ\platformTest::recordShader("),
            ),
        ),
    }
    if fixture_name not in hooks:
        return
    relative_path, replacements = hooks[fixture_name]
    path = mod / relative_path
    source = path.read_text()
    for pattern, replacement in replacements:
        source, count = re.subn(pattern, lambda match: replacement, source)
        if count == 0:
            raise RuntimeError("Fixture observation boundary was not found: " + pattern)
    path.write_text(source)


def isolate_callbacks(mod):
    """Keep native callback signatures and grenade input, while removing account/gameplay hooks."""
    callback = mod / "maps/mp/gametypes/_callbacksetup.gsc"
    source = callback.read_text()
    # Public callback names/signatures are the boundary under test. The expression
    # accepts ordinary whitespace changes and leaves unrelated helper functions intact.
    pattern = re.compile(
        r"(?ms)^(CodeCallback_\w+)\s*(\([^)]*\))[ \t]*(?://[^\n]*)?\s*\{.*?^\}"
    )
    declared_callbacks = re.findall(r"(?m)^CodeCallback_\w+\s*\(", source)

    def empty_callback(match):
        if match.group(1) == "CodeCallback_FragButton":
            return match.group(0)
        return match.group(1) + match.group(2) + "\n{\n}"

    source, count = pattern.subn(empty_callback, source)
    if count == 0 or count != len(declared_callbacks):
        raise RuntimeError(
            "Could not isolate every engine callback in the selected script release"
        )
    callback.write_text(source)
    game = mod / "maps/mp/gametypes/cj.gsc"
    source, count = re.subn(
        r"(?m)^main\s*\(\s*\)\s*\{",
        lambda match: match.group(0) + "\n    thread openCJ\\platformTest::main();",
        game.read_text(),
    )
    if count != 1:
        raise RuntimeError("Expected one gametype entry point for the fixture")
    game.write_text(source)
    # The emptied StartGameType callback cannot initialize the production database
    # or frame loop. The fixture explicitly initializes the components it exercises.


def prepare_fixture(options, home):
    mod = home / "mods/opencj"
    mod.mkdir(parents=True)
    copy_scripts(options, mod)
    original_hashes = script_hashes(mod)
    for asset in ("mod.ff", "z_opencj.iwd"):
        (mod / asset).symlink_to("/mod-assets/" + asset)
    (home / "usermaps").symlink_to("/game/usermaps")
    (home / "steamclient.so").symlink_to("/game/steamclient.so")
    (home / "plugins").mkdir()
    shutil.copyfile(options.fixture, mod / "opencj/platformtest.gsc")
    if options.fixture.name == "demo-timelines.gsc":
        # Timeline scenarios also exercise location selection through this companion fixture.
        shutil.copyfile(
            ROOT / "dev-tools/tests/demo-selection.gsc",
            mod / "opencj/demoselectiontest.gsc",
        )
    install_observation_hooks(mod, options.fixture.name)
    isolate_callbacks(mod)
    return original_hashes, script_hashes(mod)


def server_command(options, home, container_name, map_name):
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
        options.binary,
    ]
    settings = {
        "fs_basepath": "/game",
        "fs_homepath": container_home,
        "fs_game": "mods/opencj",
        "dedicated": "2",
        "net_port": "28965",  # Container-only port; it is never published on the host.
        "sv_maxclients": "2",
        "sv_authorizemode": "0",
        "com_hunkMegs": "1024",
        "developer": "1",
        "g_gametype": "cj",
        "opencj_isolated_demo_test": "1",
    }
    for setting, value in settings.items():
        command.extend(["+set", setting, value])
    command.extend(["+map", map_name])
    return command


def wait_for_fixture(container_name, completion_marker):
    """Bound the wait and retain the engine's own error when the container exits."""
    deadline = time.monotonic() + COMPLETION_TIMEOUT_SECONDS
    log = ""
    while time.monotonic() < deadline:
        time.sleep(1)
        result = subprocess.run(
            ["docker", "logs", container_name], capture_output=True, text=True
        )
        log = result.stdout + result.stderr
        if completion_marker in log or any(error in log for error in SCRIPT_ERRORS):
            break
        running = subprocess.check_output(
            ["docker", "inspect", "--format", "{{.State.Running}}", container_name],
            text=True,
        ).strip()
        if running != "true":
            break
    return log


def has_libcod_mapping(container_name):
    """Check the actual engine process, so a plugin cannot silently satisfy missing native APIs."""
    result = subprocess.run(
        [
            "docker",
            "exec",
            container_name,
            "sh",
            "-c",
            "grep -il libcod /proc/[0-9]*/maps 2>/dev/null || true",
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode:
        raise RuntimeError("Could not inspect the isolated server's loaded libraries")
    return bool(result.stdout.strip())


def run_fixture(options, map_name):
    tag = "demo-viewing-24-" + uuid.uuid4().hex[:8]
    home = ROOT / "dev-tools/local" / tag
    source_hashes, _ = prepare_fixture(options, home)
    return run_prepared_fixture(options, home, map_name, source_hashes)


def run_prepared_fixture(options, home, map_name, source_hashes):
    """Run an already prepared private copy and retain its actual source hashes."""
    fixture_hashes = script_hashes(home / "mods/opencj")
    container_name = "opencj-" + home.name
    try:
        subprocess.run(
            server_command(options, home, container_name, map_name),
            cwd=ROOT / "dev-tools",
            check=True,
            capture_output=True,
        )
        log = wait_for_fixture(container_name, options.completion_marker)
        (home / "console.log").write_text(log)
        successful_marker = re.search(
            re.escape(options.completion_marker) + r"\s+failures=0(?:\s|$)", log
        )
        passed = bool(successful_marker) and not any(
            error in log for error in SCRIPT_ERRORS
        )
        libcod_loaded = None
        if passed:
            libcod_loaded = has_libcod_mapping(container_name)
            passed = not libcod_loaded
        prefix = options.completion_marker.split(" COMPLETE")[0]
        summary = [
            line
            for line in log.splitlines()
            if prefix in line or re.search(r"\bCOMPLETE(?:\s|$)", line)
        ]
        report = {
            "baseline": options.baseline,
            "map": map_name,
            "engineSha256": hashlib.sha256(options.engine.read_bytes()).hexdigest(),
            "libcodLoaded": libcod_loaded,
            "sourceHashes": source_hashes,
            "fixtureHashes": fixture_hashes,
            "passed": passed,
            "summary": summary,
        }
        (home / "result.json").write_text(json.dumps(report, indent=2) + "\n")
        print(
            map_name + "\n" + "\n".join(summary) + "\nEvidence: " + str(home),
            flush=True,
        )
        for error in SCRIPT_ERRORS:
            if error in log:
                position = log.index(error)
                print(log[position : position + 1400], flush=True)
        if not passed:
            raise RuntimeError(
                "GSC fixture failed or timed out; see " + str(home / "console.log")
            )
        return report
    finally:
        subprocess.run(["docker", "rm", "-f", container_name], capture_output=True)


def main():
    options = parse_options()
    for map_name in options.maps:
        run_fixture(options, map_name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
