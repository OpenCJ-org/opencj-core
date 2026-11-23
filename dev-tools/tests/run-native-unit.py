"""Build and run current geometry, player and demo-technique fixtures without a game server."""

from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    compiler = shutil.which("g++")
    if compiler is None:
        raise SystemExit("g++ with C++17 and 32-bit development libraries is required.")
    local = ROOT / "dev-tools/local"
    local.mkdir(exist_ok=True)
    sources = [
        "demo-technique-24.cpp",
        "native-player.cpp",
        "platform-wall-geometry.cpp",
        "platform-collision-sources.cpp",
    ]
    # Remove this run's binaries even when a compile or assertion fails.
    with tempfile.TemporaryDirectory(prefix="native-unit-", dir=local) as directory:
        for source in sources:
            output = Path(directory) / Path(source).stem
            command = [
                compiler,
                "-std=c++17",
                "-O2",
                "-m32",
                "-DCOD4",
                "-ffunction-sections",
                "-fdata-sections",
                "-Wl,--gc-sections",
                str(ROOT / "dev-tools/tests" / source),
                "-o",
                str(output),
            ]
            subprocess.run(command, check=True, cwd=ROOT)
            subprocess.run([str(output)], check=True, cwd=ROOT)


if __name__ == "__main__":
    main()
