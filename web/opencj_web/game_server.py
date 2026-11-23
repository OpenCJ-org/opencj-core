"""Ask the game server for its current map and player count over the Quake 3 status protocol."""

import re
import socket
from dataclasses import dataclass

OUT_OF_BAND_PREFIX = b"\xff\xff\xff\xff"
STATUS_REQUEST = OUT_OF_BAND_PREFIX + b"getstatus\n"
STATUS_REPLY_HEADER = OUT_OF_BAND_PREFIX + b"statusResponse\n"
# A full CoD4 status reply with 64 players stays well below this size.
MAX_STATUS_REPLY_BYTES = 16 * 1024
COLOR_CODE_PATTERN = re.compile(r"\^[0-9]")


@dataclass(frozen=True)
class ServerStatus:
    map_name: str
    player_count: int
    max_players: int


def strip_color_codes(text):
    """Remove CoD color codes such as ^1 from a name."""
    return COLOR_CODE_PATTERN.sub("", text)


def _parse_info_string(info_text):
    # The info string alternates keys and values: \key\value\key\value
    fields = info_text.split("\\")
    if len(fields) < 3 or fields[0] != "":
        raise ValueError("Status reply has no info string")
    settings = {}
    for key_index in range(1, len(fields) - 1, 2):
        settings[fields[key_index]] = fields[key_index + 1]
    return settings


def parse_status_reply(reply_bytes):
    """Decode a statusResponse packet; raise ValueError when it is malformed."""
    if not reply_bytes.startswith(STATUS_REPLY_HEADER):
        raise ValueError("Not a status reply")
    body = reply_bytes[len(STATUS_REPLY_HEADER):].decode("latin-1")
    lines = body.split("\n")
    settings = _parse_info_string(lines[0])

    map_name = settings.get("mapname", "")
    if map_name == "":
        raise ValueError("Status reply has no map name")
    try:
        max_players = int(settings.get("sv_maxclients", ""))
    except ValueError:
        raise ValueError("Status reply has no player limit") from None

    # Each remaining non-empty line describes one connected player: score ping "name"
    player_lines = [line for line in lines[1:] if line.strip() != ""]
    return ServerStatus(
        map_name=strip_color_codes(map_name),
        player_count=len(player_lines),
        max_players=max_players,
    )


def query_status(host, port, timeout_seconds):
    """Return the server's status, or None when it does not answer in time or answers badly."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as status_socket:
            status_socket.settimeout(timeout_seconds)
            status_socket.sendto(STATUS_REQUEST, (host, port))
            reply_bytes, _ = status_socket.recvfrom(MAX_STATUS_REPLY_BYTES)
    except OSError:
        return None
    try:
        return parse_status_reply(reply_bytes)
    except ValueError:
        return None
