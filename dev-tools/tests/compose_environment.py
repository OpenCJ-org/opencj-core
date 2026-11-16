"""Resolve prerequisites for tests in the selected development installation."""

from functools import lru_cache
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]


@lru_cache(maxsize=1)
def database_container():
    """Use this checkout's Compose project; never fall back to another database."""
    directory = ROOT / "dev-tools"
    env_file = directory / ".env"
    if not env_file.is_file():
        raise RuntimeError("Run dev.py init in a separate test installation first.")
    containers = subprocess.check_output(
        [
            "docker",
            "compose",
            "--env-file",
            str(env_file),
            "ps",
            "--status",
            "running",
            "--quiet",
            "db",
        ],
        cwd=directory,
        text=True,
    ).split()
    if len(containers) != 1:
        raise RuntimeError(
            "Expected one running db service in the selected Compose project. "
            "Start it with docker compose up -d --wait db."
        )
    return containers[0]


@lru_cache(maxsize=1)
def database_network():
    networks = json.loads(
        subprocess.check_output(
            [
                "docker",
                "inspect",
                "--format",
                "{{json .NetworkSettings.Networks}}",
                database_container(),
            ],
            text=True,
        )
    )
    if len(networks) != 1:
        raise RuntimeError("Expected one network for the selected test database.")
    return next(iter(networks))


def workspace_file(value):
    """Validate an input before translating it to the container's workspace."""
    path = Path(value).expanduser().resolve()
    if not path.is_relative_to(ROOT) or not path.is_file():
        raise ValueError("Input must be an existing file inside this core checkout.")
    return path


def workspace_path(value):
    return "/workspace/" + workspace_file(value).relative_to(ROOT).as_posix()


def capacity_cpu_set(value=None):
    """Keep the two-core comparison valid on hosts with different CPU numbering."""
    available = set(os.sched_getaffinity(0))
    if value is None:
        if len(available) < 2:
            raise ValueError("Query-capacity tests require at least two available CPU cores.")
        selected = sorted(available)[:2]
    else:
        selected = set()
        try:
            for part in value.split(","):
                bounds = [int(item) for item in part.split("-")]
                if len(bounds) == 1:
                    selected.add(bounds[0])
                elif len(bounds) == 2 and bounds[0] <= bounds[1]:
                    # Check the bounds before expanding a caller-supplied range.
                    if bounds[0] < 0 or bounds[1] > max(available):
                        raise ValueError
                    selected.update(range(bounds[0], bounds[1] + 1))
                else:
                    raise ValueError
        except ValueError:
            raise ValueError("--cpu-set must select two available CPU cores.") from None
        if len(selected) != 2 or not selected <= available:
            raise ValueError("--cpu-set must select two available CPU cores.")
    return ",".join(str(cpu) for cpu in sorted(selected))
