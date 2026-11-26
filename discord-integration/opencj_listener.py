"""Unix socket between the bridge and one game server.

The bridge owns the socket; the game server connects to it. Game events arrive as
newline-framed lines (see opencj_events) and Discord chat goes back the same way.
Only the standard library is used so the portable tests can import this module.
"""

import asyncio
import logging
import os
import socket
import stat

from opencj_events import parse_game_event

LOG = logging.getLogger(__name__)

RECEIVE_CHUNK_BYTES = 4096
# The game sends lines of at most 512 bytes (opencj_discord.cpp). A longer run of bytes
# without a line break means the stream is out of step, so it is dropped up to the next one.
GAME_LINE_MAX_BYTES = 1024
# Must stay below DISCORD_LINE_MAX_BYTES in opencj_discord.cpp, including the line break.
GAME_BOUND_LINE_MAX_BYTES = 511
# A game that stops reading must not hold Discord messages back for ever.
SEND_TIMEOUT_SECONDS = 5
# Owner and group only: the game joins the bridge's group to connect.
SOCKET_FILE_MODE = 0o660
DISCORD_CHAT_PREFIX = '^8[^7Discord^8]^7 '


def check_socket_directory(directory):
    """Refuse a folder where other local users could replace or reach the socket."""
    directory_status = os.stat(directory)
    if not stat.S_ISDIR(directory_status.st_mode):
        raise RuntimeError('Socket folder is not a directory: ' + directory)
    if directory_status.st_mode & stat.S_IWOTH:
        raise RuntimeError('Socket folder is writable by every user, use a private folder: ' + directory)


def remove_stale_socket(socket_path):
    """Remove a socket left by an earlier run, but never another kind of file."""
    try:
        path_status = os.lstat(socket_path)
    except FileNotFoundError:
        return
    if not stat.S_ISSOCK(path_status.st_mode):
        raise RuntimeError('Socket path exists and is not a socket: ' + socket_path)
    os.unlink(socket_path)


def format_discord_chat_line(name, message):
    """One game-bound line; name and message must already be game-safe (see util.to_game_text)."""
    line = (DISCORD_CHAT_PREFIX + name + ': ' + message).encode('ascii', 'ignore')
    return line[:GAME_BOUND_LINE_MAX_BYTES - 1] + b'\n'


class GameLineReader:
    """Split a byte stream into lines, keeping a partial line until the rest arrives."""

    def __init__(self):
        self.pending_bytes = bytearray()
        self.is_discarding_overlong_line = False

    def feed(self, received_bytes):
        """Return the complete lines in received_bytes plus anything kept from earlier."""
        self.pending_bytes.extend(received_bytes)
        complete_lines = []
        while True:
            line_end = self.pending_bytes.find(b'\n')
            if line_end < 0:
                break
            line_bytes = bytes(self.pending_bytes[:line_end])
            del self.pending_bytes[:line_end + 1]
            if self.is_discarding_overlong_line:
                self.is_discarding_overlong_line = False
                continue
            complete_lines.append(line_bytes.decode('utf-8', errors='replace'))
        if len(self.pending_bytes) > GAME_LINE_MAX_BYTES:
            LOG.warning('Dropping %d bytes from the game without a line break', len(self.pending_bytes))
            self.pending_bytes.clear()
            self.is_discarding_overlong_line = True
        return complete_lines


class OpenCJListener:
    """Accepts the game server's connection and passes events both ways."""

    def __init__(self, discord_client, socket_path):
        self.discord_client = discord_client
        self.socket_path = socket_path
        self.server = None
        self.client = None
        self.client_task = None
        self.send_lock = asyncio.Lock()

    def forward_game_event(self, event):
        if self.discord_client is None:
            return
        self.discord_client.queue_game_event(event)

    async def handle_client(self, client):
        """Read events from one game connection until it closes or is replaced."""
        loop = asyncio.get_running_loop()
        line_reader = GameLineReader()
        try:
            while True:
                received_bytes = await loop.sock_recv(client, RECEIVE_CHUNK_BYTES)
                if not received_bytes:
                    break
                for line in line_reader.feed(received_bytes):
                    if len(line) == 0:
                        continue
                    event = parse_game_event(line)
                    if event is not None:
                        self.forward_game_event(event)
        except OSError as error:
            LOG.warning('Game server connection failed: %s', error)
        finally:
            client.close()
            # A newer connection may already have replaced this one; leave it alone.
            if self.client is client:
                self.client = None
                self.client_task = None
            LOG.info('Game server disconnected')

    def replace_client(self, client):
        """Only one game server talks to a bridge, so a new connection ends the old one."""
        previous_task = self.client_task
        if previous_task is not None:
            LOG.warning('Another game server connected, dropping the previous connection')
            previous_task.cancel()
        self.client = client
        self.client_task = asyncio.get_running_loop().create_task(self.handle_client(client))

    async def on_discord_message(self, name, message):
        """Send one Discord chat line to the game, or drop it when no game is connected."""
        client = self.client
        if client is None:
            LOG.info('Dropping Discord message, no game server is connected')
            return
        line = format_discord_chat_line(name, message)
        loop = asyncio.get_running_loop()
        # Concurrent sendall calls could interleave partial writes and break the line framing,
        # so sends take turns. Waiting for a turn is bounded too, or a stalled game would let
        # waiting messages pile up.
        try:
            await asyncio.wait_for(self.send_lock.acquire(), SEND_TIMEOUT_SECONDS)
        except asyncio.TimeoutError:
            LOG.warning('Dropping Discord message, the game is not reading')
            return
        try:
            await asyncio.wait_for(loop.sock_sendall(client, line), SEND_TIMEOUT_SECONDS)
        except (OSError, asyncio.TimeoutError) as error:
            LOG.warning('Could not send Discord message to the game: %r', error)
            # A partly sent line would corrupt the stream, so end this connection.
            if self.client is client and self.client_task is not None:
                self.client_task.cancel()
        finally:
            self.send_lock.release()

    async def start(self):
        """Create the socket and accept game server connections for ever."""
        if not self.socket_path:
            raise RuntimeError('Game server listener needs a socket path')
        check_socket_directory(os.path.dirname(os.path.abspath(self.socket_path)))
        remove_stale_socket(self.socket_path)
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(self.socket_path)
        os.chmod(self.socket_path, SOCKET_FILE_MODE)
        self.server.listen(1)
        self.server.setblocking(False)
        LOG.info('Listening for the game server on %s', self.socket_path)
        loop = asyncio.get_running_loop()
        while True:
            client, _ = await loop.sock_accept(self.server)
            client.setblocking(False)
            LOG.info('Game server connected')
            self.replace_client(client)
