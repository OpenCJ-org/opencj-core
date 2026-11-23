"""Check native demo storage in a temporary build container, without game assets."""

import argparse
from pathlib import Path
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]


def main():
    """Compile production demo code with script-return stubs, then run its regressions."""
    argparse.ArgumentParser(description=__doc__).parse_args()
    local = ROOT / "dev-tools/local"
    local.mkdir(exist_ok=True)
    container_name = "opencj-demo-storage-" + uuid.uuid4().hex[:12]
    compose = ["docker", "compose"]
    run = compose + [
        "run",
        "--rm",
        "--no-deps",
        "--name",
        container_name,
        "--workdir",
        "/workspace",
    ]
    with tempfile.TemporaryDirectory(prefix="demo-storage-", dir=local) as directory:
        output = "/workspace/" + str(Path(directory).relative_to(ROOT) / "demo-storage")
        try:
            subprocess.run(
                run
                + [
                    "--entrypoint",
                    "g++",
                    "build",
                    "-std=c++17",
                    "-O2",
                    "-m32",
                    "-DCOD4",
                    "-ffunction-sections",
                    "-fdata-sections",
                    "-Wl,--gc-sections",
                    "dev-tools/tests/demo-storage.cpp",
                    "-lz",
                    "-o",
                    output,
                ],
                cwd=ROOT / "dev-tools",
                check=True,
                timeout=120,
            )
            subprocess.run(
                run + ["--entrypoint", output, "build"],
                cwd=ROOT / "dev-tools",
                check=True,
                timeout=30,
            )
        finally:
            # Killing the Docker client alone can leave its container running.
            subprocess.run(
                ["docker", "rm", "-f", container_name],
                capture_output=True,
                timeout=30,
            )


if __name__ == "__main__":
    main()
