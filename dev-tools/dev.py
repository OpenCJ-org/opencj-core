#!/usr/bin/env python3
"""OpenCJ development environment; Python standard library only."""

import argparse
import ipaddress
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys

HERE = Path(__file__).resolve().parent
MIN_UNPRIVILEGED_PORT = 1024
MAX_PORT = 65535
CREDENTIAL_BYTES = 24
COMPONENTS = ("server-ext", "server-gsc", "server-db", "client-mod", "discord-integration")


def prepare_engine(root):
    """Initialize only a missing CoD4 submodule; preserve existing local work."""
    engine = root / "cod4x-server"
    if (engine / ".git").exists():
        checkout = subprocess.check_output(
            ["git", "-C", str(engine), "rev-parse", "--show-toplevel"], text=True
        ).strip()
        if Path(checkout).resolve() != engine.resolve():
            raise ValueError("The CoD4 engine must be its own submodule checkout.")
        print("Keeping the existing CoD4 engine checkout and local changes.")
        return
    if engine.exists() and any(engine.iterdir()):
        raise ValueError("The CoD4 engine directory is not empty and has no Git checkout.")
    run("git", "-C", str(root), "submodule", "update", "--init", "--", "cod4x-server")


def run(*args):
    subprocess.run(args, cwd=HERE, check=True)


def compose(*args):
    if not (HERE / ".env").is_file():
        raise ValueError("Run init first.")
    run("docker", "compose", "--env-file", str(HERE / ".env"), *args)


def dotenv(value):
    """Quote one Compose value; refuse characters that would change its structure."""
    value = str(value)
    if any(char in value for char in "\r\n'"):
        raise ValueError("Paths must not contain newlines or single quotes.")
    return "'" + value + "'"


def validate_installation(args):
    """Resolve the source and asset paths, rejecting invalid setup inputs before writes."""
    root = HERE.parent
    game_dir = Path(args.game_dir).expanduser().resolve()
    mod_dir = (
        Path(args.mod_dir).expanduser().resolve() if args.mod_dir else game_dir / "mods" / "opencj"
    )
    for folder in (game_dir / "main", game_dir / "zone"):
        if not folder.is_dir():
            raise ValueError(f"Required directory is missing: {folder}")
    if not re.fullmatch(r"[a-z0-9_]+", args.map):
        raise ValueError("Map names may contain lowercase letters, numbers and underscores.")
    if not MIN_UNPRIVILEGED_PORT <= args.port <= MAX_PORT:
        raise ValueError("Port must be between 1024 and 65535.")
    ipaddress.IPv4Address(args.bind_ip)
    for path in (root, game_dir, mod_dir):
        dotenv(path)
    if not (root / ".gitmodules").is_file():
        raise ValueError("Expected the complete opencj-core checkout, including .gitmodules.")
    for name in COMPONENTS:
        if not (root / name).is_dir():
            raise ValueError(f"Missing core component: {name}. Restore the complete checkout.")
    return root, game_dir, mod_dir


def initialize(args):
    """Validate the checkout and create private configuration for a new installation."""
    if HERE.name != "dev-tools":
        raise ValueError("Run this helper from the dev-tools directory inside opencj-core.")
    if (HERE / ".env").exists():
        raise ValueError(
            "Already initialized. Edit .env and local/runtime/mods/opencj/opencj-dev.cfg to adjust settings; existing configuration was preserved."
        )
    root, game_dir, mod_dir = validate_installation(args)
    # Validate paths and options before initialization can fetch engine files.
    prepare_engine(root)
    runtime_dir = HERE / "local" / "runtime"
    runtime_dir.mkdir(parents=True, exist_ok=True)
    (runtime_dir / "plugins").mkdir(exist_ok=True)
    (runtime_dir / "mods" / "opencj").mkdir(parents=True, exist_ok=True)
    (HERE / "local" / "sockets").mkdir(exist_ok=True)
    database_password = secrets.token_hex(CREDENTIAL_BYTES)
    # Both configurations must use the same fresh gameplay database credential.
    settings = {
        "SOURCE_ROOT": root,
        "GAME_DIR": game_dir,
        "MOD_DIR": mod_dir,
        "DEV_UID": os.getuid(),
        "DEV_GID": os.getgid(),
        "GAME_GID": game_dir.stat().st_gid,
        "DB_PASSWORD": database_password,
        "DB_ROOT_PASSWORD": secrets.token_hex(CREDENTIAL_BYTES),
        "SERVER_PORT": args.port,
        "BIND_IP": args.bind_ip,
        "START_MAP": args.map,
    }
    config = runtime_dir / "mods" / "opencj" / "opencj-dev.cfg"
    if config.exists():
        raise ValueError(f"Existing server configuration preserved: {config}")
    config.write_text(
        'set sv_hostname "OpenCJ Development"\n'
        'set sv_punkbuster "0"\nset sv_allowDownload "1"\n'
        'set db_host "db"\nset db_port "3306"\nset db_user "opencj"\n'
        f'set db_pass "{database_password}"\nset db_base "openCJ_cod"\n',
        encoding="utf-8",
    )
    config.chmod(0o600)
    env_file = HERE / ".env"
    env_file.write_text(
        "".join(f"{key}={dotenv(value)}\n" for key, value in settings.items()), encoding="utf-8"
    )
    env_file.chmod(0o600)
    print(
        "Initialized. Follow ../docs/setup/development.md: create the external volume, start db, bootstrap the empty schema, then build and start the server."
    )


def main():
    """Dispatch the selected development command and report actionable failures."""
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    init_parser = commands.add_parser(
        "init", help="Initialize the CoD4 submodule and create local configuration"
    )
    init_parser.add_argument(
        "--game-dir", required=True, help="Existing CoD4 directory containing main/ and zone/"
    )
    init_parser.add_argument(
        "--mod-dir", help="Compiled assets directory; defaults to GAME_DIR/mods/opencj"
    )
    init_parser.add_argument("--map", default="mp_killhouse")
    init_parser.add_argument("--port", default=28961, type=int)
    init_parser.add_argument(
        "--bind-ip",
        default="127.0.0.1",
        help="Host IP to publish; use the server's LAN/VPN IP for remote play",
    )
    for command in ("build", "up", "down", "logs", "restart", "check", "db-shell"):
        commands.add_parser(command)
    args = parser.parse_args()
    try:
        if args.command == "init":
            if sys.platform != "linux":
                raise ValueError("Run init on the Ubuntu server through SSH.")
            initialize(args)
        elif args.command == "build":
            compose("stop", "server")
            compose("build", "build", "server")
            compose("run", "--rm", "--no-deps", "build")
        elif args.command == "up":
            compose("up", "-d", "--wait", "db")
            run(sys.executable, str(HERE / "scripts/bootstrap-db.py"), "--check")
            compose("up", "-d", "--wait", "server")
        elif args.command == "restart":
            compose("restart", "server")
        elif args.command == "down":
            compose("down")
        elif args.command == "logs":
            compose("logs", "-f", "server")
        elif args.command == "db-shell":
            compose(
                "exec",
                "db",
                "sh",
                "-c",
                'MYSQL_PWD="$MYSQL_PASSWORD" exec mysql -u opencj openCJ_cod4',
            )
        else:
            compose("config", "--quiet")
            compose("ps")
            compose(
                "exec",
                "db",
                "sh",
                "-c",
                'MYSQL_PWD="$MYSQL_PASSWORD" mysql -u opencj openCJ_cod4 -e "SHOW TABLES; SHOW FUNCTION STATUS WHERE Db = DATABASE();"',
            )
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
