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
REPOS = {
    "cod4x-server": "opencj", "server-ext": "master", "server-gsc": "master",
    "server-db": "master", "client-mod": "master", "libcod": "opencj",
    "discord-integration": None,
}


def run(*args):
    subprocess.run(args, cwd=HERE, check=True)


def compose(*args):
    if not (HERE / ".env").is_file():
        raise ValueError("Run init first.")
    run("docker", "compose", "--env-file", str(HERE / ".env"), *args)


def dotenv(value):
    value = str(value)
    if any(char in value for char in "\r\n'"):
        raise ValueError("Paths must not contain newlines or single quotes.")
    return "'" + value + "'"


def initialize(args):
    if HERE.name != "dev-tools":
        raise ValueError("Place this repository in a directory named dev-tools.")
    if (HERE / ".env").exists():
        raise ValueError("Already initialized. Edit .env and local/runtime/mods/opencj/opencj-dev.cfg to adjust settings; existing configuration was preserved.")
    root = HERE.parent
    game = Path(args.game_dir).expanduser().resolve()
    mod = Path(args.mod_dir).expanduser().resolve() if args.mod_dir else game / "mods" / "opencj"
    for folder in (game / "main", game / "zone"):
        if not folder.is_dir():
            raise ValueError(f"Required directory is missing: {folder}")
    if not re.fullmatch(r"[a-z0-9_]+", args.map):
        raise ValueError("Map names may contain lowercase letters, numbers and underscores.")
    if not 1024 <= args.port <= 65535:
        raise ValueError("Port must be between 1024 and 65535.")
    ipaddress.IPv4Address(args.bind_ip)
    for path in (root, game, mod):
        dotenv(path)
    for name, branch in REPOS.items():
        target = root / name
        url = f"https://github.com/OpenCJ-org/{name}.git"
        if target.exists():
            origin = subprocess.check_output(["git", "-C", str(target), "remote", "get-url", "origin"], text=True).strip()
            if origin.removesuffix(".git").lower() not in {
                url.removesuffix(".git").lower(),
                f"git@github.com:OpenCJ-org/{name}".lower(),
            }:
                raise ValueError(f"Unexpected origin for {target}: {origin}")
            print(f"Keeping existing checkout: {name} (no fetch, reset or branch switch)")
        else:
            run("git", "clone", *(["--branch", branch] if branch else []), url, str(target))
    runtime = HERE / "local" / "runtime"
    runtime.mkdir(parents=True, exist_ok=True)
    (runtime / "plugins").mkdir(exist_ok=True)
    (runtime / "mods" / "opencj").mkdir(parents=True, exist_ok=True)
    (HERE / "local" / "sockets").mkdir(exist_ok=True)
    password = secrets.token_hex(24)
    settings = {
        "SOURCE_ROOT": root, "GAME_DIR": game, "MOD_DIR": mod,
        "DEV_UID": os.getuid(), "DEV_GID": os.getgid(),
        "GAME_GID": game.stat().st_gid,
        "DB_PASSWORD": password, "DB_ROOT_PASSWORD": secrets.token_hex(24),
        "SERVER_PORT": args.port, "BIND_IP": args.bind_ip, "START_MAP": args.map,
    }
    config = runtime / "mods" / "opencj" / "opencj-dev.cfg"
    if config.exists():
        raise ValueError(f"Existing server configuration preserved: {config}")
    config.write_text(
        'set sv_hostname "OpenCJ Development"\n'
        'set sv_punkbuster "0"\nset sv_allowDownload "1"\n'
        'set db_host "db"\nset db_port "3306"\nset db_user "opencj"\n'
        f'set db_pass "{password}"\nset db_base "openCJ_cod"\n'
        'loadPlugin libcod4_1_8x\n', encoding="utf-8")
    config.chmod(0o600)
    env = HERE / ".env"
    env.write_text("".join(f"{key}={dotenv(value)}\n" for key, value in settings.items()), encoding="utf-8")
    env.chmod(0o600)
    print("Initialized. Next: python3 dev.py build, then python3 dev.py up")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    init = commands.add_parser("init", help="Clone missing repositories and create local configuration")
    init.add_argument("--game-dir", required=True, help="Existing CoD4 directory containing main/ and zone/")
    init.add_argument("--mod-dir", help="Compiled assets directory; defaults to GAME_DIR/mods/opencj")
    init.add_argument("--map", default="mp_killhouse")
    init.add_argument("--port", default=28961, type=int)
    init.add_argument("--bind-ip", default="127.0.0.1", help="Host IP to publish; use the server's LAN/VPN IP for remote play")
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
            compose("up", "-d", "--wait", "db", "server")
        elif args.command == "restart":
            compose("restart", "server")
        elif args.command == "down":
            compose("down")
        elif args.command == "logs":
            compose("logs", "-f", "server")
        elif args.command == "db-shell":
            compose("exec", "db", "sh", "-c", 'MYSQL_PWD="$MYSQL_PASSWORD" exec mysql -u opencj openCJ_cod4')
        else:
            compose("config", "--quiet")
            compose("ps")
            compose("exec", "db", "sh", "-c", 'MYSQL_PWD="$MYSQL_PASSWORD" mysql -u opencj openCJ_cod4 -e "SHOW TABLES; SHOW FUNCTION STATUS WHERE Db = DATABASE();"')
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
