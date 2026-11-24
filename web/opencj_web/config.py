"""Read the generator's settings from environment variables."""

import os
import re
from dataclasses import dataclass
from pathlib import Path

# Only real Discord invite links are rendered, so a typo cannot send visitors elsewhere.
DISCORD_INVITE_PATTERN = re.compile(r"https://(discord\.gg|discord\.com/invite)/[A-Za-z0-9-]+")


@dataclass(frozen=True)
class Settings:
    database_host: str
    database_port: int
    database_name: str
    database_user: str
    database_password: str
    game_server_host: str
    game_server_port: int
    connect_address: str
    discord_invite_url: str  # Empty when no invite is configured
    releases_dir: Path
    usermaps_dir: Path
    output_dir: Path
    rebuild_interval_seconds: int


def _require_text(name):
    value = os.environ.get(name, "")
    if value == "":
        raise ValueError("Missing setting " + name)
    return value


def _require_positive_int(name):
    text = _require_text(name)
    try:
        value = int(text)
    except ValueError:
        raise ValueError(name + " must be a whole number") from None
    if value <= 0:
        raise ValueError(name + " must be greater than zero")
    return value


def read_database_password():
    """Installed instances mount a secret file; standalone Compose keeps its existing environment input."""
    secret_path = os.environ.get("WEB_DB_PASSWORD_FILE")
    if secret_path:
        password = Path(secret_path).read_text().strip()
        if not password:
            raise ValueError("WEB_DB_PASSWORD_FILE is empty")
        return password
    return _require_text("WEB_DB_PASSWORD")


def read_discord_invite_url():
    """Return the optional invite link, or "" when unset; raise ValueError for anything else."""
    invite_url = os.environ.get("WEB_DISCORD_INVITE_URL", "").strip()
    if invite_url != "" and DISCORD_INVITE_PATTERN.fullmatch(invite_url) is None:
        raise ValueError("WEB_DISCORD_INVITE_URL must look like https://discord.gg/<code>")
    return invite_url


def load_settings():
    """Return validated settings; raise ValueError naming the first missing or invalid one."""
    return Settings(
        database_host=_require_text("WEB_DB_HOST"),
        database_port=_require_positive_int("WEB_DB_PORT"),
        database_name=_require_text("WEB_DB_NAME"),
        database_user=_require_text("WEB_DB_USER"),
        database_password=read_database_password(),
        game_server_host=_require_text("WEB_GAME_HOST"),
        game_server_port=_require_positive_int("WEB_GAME_PORT"),
        connect_address=_require_text("WEB_CONNECT_ADDRESS"),
        discord_invite_url=read_discord_invite_url(),
        releases_dir=Path(_require_text("WEB_RELEASES_DIR")),
        usermaps_dir=Path(_require_text("WEB_USERMAPS_DIR")),
        output_dir=Path(_require_text("WEB_OUTPUT_DIR")),
        rebuild_interval_seconds=_require_positive_int("WEB_REBUILD_INTERVAL_SECONDS"),
    )
