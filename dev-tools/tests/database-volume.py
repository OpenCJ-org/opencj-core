"""Verify external-volume preservation using only a disposable probe project."""

import json
from pathlib import Path
import re
import subprocess
import uuid

from compose_environment import database_container

ROOT = Path(__file__).resolve().parents[2]
COMMAND_TIMEOUT_SECONDS = 60


def run_command(arguments, *, cwd=None):
    result = subprocess.run(
        arguments, cwd=cwd, text=True, capture_output=True, timeout=COMMAND_TIMEOUT_SECONDS
    )
    if result.returncode:
        # Compose config output can contain installation settings; do not print it.
        raise RuntimeError("Probe command failed: " + " ".join(arguments[:3]))
    return result


def probe_volume_exists(volume_name):
    result = run_command(
        ["docker", "volume", "ls", "--filter", "name=" + volume_name, "--format", "{{.Name}}"]
    )
    return volume_name in result.stdout.splitlines()


def selected_database_volume(container):
    result = run_command(["docker", "inspect", "--format", "{{json .Mounts}}", container])
    mounts = json.loads(result.stdout)
    database_mounts = [mount for mount in mounts if mount["Destination"] == "/var/lib/mysql"]
    if len(database_mounts) != 1 or database_mounts[0]["Type"] != "volume":
        raise RuntimeError("Expected one named volume for the selected database.")
    return database_mounts[0]["Name"]


def verify_compose_volume(volume_name):
    result = run_command(
        ["docker", "compose", "config", "--format", "json"], cwd=ROOT / "dev-tools"
    )
    database_volume = json.loads(result.stdout)["volumes"]["database"]
    assert database_volume["external"] is True, "Selected database volume is not external"
    assert (
        database_volume["name"] == volume_name
    ), "Compose and the running database use different volumes"


def write_probe_config(path, volume_name):
    """The probe mounts its own volume and immediately exits without running MySQL."""
    config = {
        "services": {
            "probe": {
                "image": "mysql:8.0",
                "entrypoint": ["/bin/true"],
                "volumes": ["data:/proof"],
            }
        },
        "volumes": {"data": {"external": True, "name": volume_name}},
    }
    path.write_text(json.dumps(config, indent=2) + "\n")


def remove_probe(compose_command, volume_name, owns_volume):
    """Attempt both cleanup steps, even when tearing down the probe project fails."""
    failures = []
    try:
        run_command(compose_command + ["down", "--volumes"])
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        failures.append(str(error))
    if owns_volume:
        # This invariant guards the only volume-removal command in the test.
        if not re.fullmatch(r"opencj-volume-safety-[0-9a-f]{8}-data", volume_name):
            raise RuntimeError("Refusing to remove a volume outside this probe's namespace.")
        try:
            if probe_volume_exists(volume_name):
                run_command(["docker", "volume", "rm", volume_name])
        except (RuntimeError, subprocess.TimeoutExpired) as error:
            failures.append(str(error))
    if failures:
        raise RuntimeError("Probe cleanup failed: " + "; ".join(failures))


def main():
    container = database_container()
    volume_before = selected_database_volume(container)
    verify_compose_volume(volume_before)

    project_name = "opencj-volume-safety-" + uuid.uuid4().hex[:8]
    evidence = ROOT / "dev-tools/local" / project_name
    evidence.mkdir(mode=0o700)
    probe_volume = project_name + "-data"
    config = evidence / "compose.json"
    write_probe_config(config, probe_volume)
    compose_command = ["docker", "compose", "-p", project_name, "-f", str(config)]
    owns_volume = False
    try:
        if probe_volume_exists(probe_volume):
            raise RuntimeError("Probe volume already exists; refusing to reuse it.")

        # After confirmed absence, cleanup also covers a lost reply to volume creation.
        owns_volume = True
        run_command(["docker", "volume", "create", probe_volume])
        run_command(compose_command + ["up", "-d"])
        run_command(compose_command + ["down", "--volumes"])
        run_command(["docker", "volume", "inspect", probe_volume])

        volume_after = selected_database_volume(container)
        assert volume_after == volume_before, "Selected database mount changed during the probe"
        report = {
            "passed": True,
            "selectedDatabaseVolumeUnchanged": volume_after,
            "externalProbeSurvivedDownVolumes": True,
        }
        (evidence / "result.json").write_text(json.dumps(report, indent=2) + "\n")
        print("VOLUME PASS: selected mount unchanged; disposable external volume survives teardown")
        print("Evidence: " + str(evidence))
    finally:
        remove_probe(compose_command, probe_volume, owns_volume)


if __name__ == "__main__":
    main()
