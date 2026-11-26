"""Exercise the real listener using a private temporary Unix socket."""

import asyncio
import os
from pathlib import Path
import socket
import tempfile
import unittest

from opencj_events import FIELD_SEPARATOR, PlayerMessageEvent
from opencj_listener import OpenCJListener

STATE_TIMEOUT_SECONDS = 5
STATE_POLL_SECONDS = 0.01
# Long enough for the listener to process one send before the test sends the next part.
LISTENER_SETTLE_SECONDS = 0.05
# Cuts the first event inside its name field, so the first read holds an incomplete line.
PARTIAL_EVENT_BYTES = 9


class RecordingDiscordModule:
    """Stands in for OpenCJDiscord and keeps the events the listener forwards."""

    def __init__(self):
        self.events = []

    def queue_game_event(self, event):
        self.events.append(event)


async def wait_for_listener_state(listener_task, predicate):
    while not predicate():
        if listener_task.done():
            await listener_task
        await asyncio.sleep(STATE_POLL_SECONDS)


async def receive_message(loop, client, expected_size):
    """A stream may split one send across several reads; EOF is not a full message."""
    received = bytearray()
    while len(received) < expected_size:
        chunk = await loop.sock_recv(client, expected_size - len(received))
        if not chunk:
            raise AssertionError(f"Client closed after {len(received)} of {expected_size} bytes")
        received.extend(chunk)
    return bytes(received)


async def close_fixture(listener, clients, existing_tasks):
    for client in clients:
        client.close()
    # IsolatedAsyncioTestCase owns this loop; all newly created tasks are fixture work,
    # except the task running this cleanup (setup and teardown run as separate tasks).
    fixture_tasks = asyncio.all_tasks() - existing_tasks - {asyncio.current_task()}
    for task in fixture_tasks:
        task.cancel()
    await asyncio.gather(*fixture_tasks, return_exceptions=True)
    if listener.client is not None:
        listener.client.close()
    if listener.server is not None:
        listener.server.close()


class DiscordListenerTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="opencj-listener-test-")
        self.discord_module = RecordingDiscordModule()
        socket_path = str(Path(self.directory.name) / "events.sock")
        self.listener = OpenCJListener(self.discord_module, socket_path)
        self.existing_tasks = asyncio.all_tasks()
        self.listener_task = asyncio.create_task(self.listener.start())
        self.loop = asyncio.get_running_loop()
        self.clients = []
        await asyncio.wait_for(
            wait_for_listener_state(self.listener_task, lambda: self.listener.server is not None),
            STATE_TIMEOUT_SECONDS,
        )

    async def asyncTearDown(self):
        await close_fixture(self.listener, self.clients, self.existing_tasks)
        self.directory.cleanup()

    async def connect_game_client(self):
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.setblocking(False)
        self.clients.append(client)
        await self.loop.sock_connect(client, self.listener.socket_path)
        await asyncio.wait_for(
            wait_for_listener_state(self.listener_task, lambda: self.listener.client is not None),
            STATE_TIMEOUT_SECONDS,
        )
        return client

    async def test_message_reaches_game_client(self):
        client = await self.connect_game_client()
        await self.listener.on_discord_message("Test player", "Fixture message")
        expected = b"^8[^7Discord^8]^7 Test player: Fixture message\n"
        received = await asyncio.wait_for(
            receive_message(self.loop, client, len(expected)), STATE_TIMEOUT_SECONDS
        )
        self.assertEqual(received, expected)

        client.close()
        await asyncio.wait_for(
            wait_for_listener_state(self.listener_task, lambda: self.listener.client is None),
            STATE_TIMEOUT_SECONDS,
        )

    async def test_event_split_across_reads_is_reassembled(self):
        client = await self.connect_game_client()
        line = FIELD_SEPARATOR.join(["0", "Runner", "hello world"]).encode() + b"\n"
        await self.loop.sock_sendall(client, line[:PARTIAL_EVENT_BYTES])
        await asyncio.sleep(LISTENER_SETTLE_SECONDS)
        await self.loop.sock_sendall(client, line[PARTIAL_EVENT_BYTES:] + b"garbage line\n" + line)
        await asyncio.wait_for(
            wait_for_listener_state(self.listener_task, lambda: len(self.discord_module.events) == 2),
            STATE_TIMEOUT_SECONDS,
        )
        expected = PlayerMessageEvent("Runner", "hello world")
        self.assertEqual(self.discord_module.events, [expected, expected])

    async def test_new_game_client_replaces_the_previous_one(self):
        first_client = await self.connect_game_client()
        first_connection = self.listener.client
        second_client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        second_client.setblocking(False)
        self.clients.append(second_client)
        await self.loop.sock_connect(second_client, self.listener.socket_path)
        await asyncio.wait_for(
            wait_for_listener_state(
                self.listener_task,
                lambda: self.listener.client is not None and self.listener.client is not first_connection,
            ),
            STATE_TIMEOUT_SECONDS,
        )
        second_connection = self.listener.client
        # The old connection's cleanup must not clear the new one.
        self.assertEqual(await self.loop.sock_recv(first_client, 1), b"")
        await asyncio.sleep(LISTENER_SETTLE_SECONDS)
        self.assertIs(self.listener.client, second_connection)

    async def test_socket_is_private(self):
        mode = os.stat(self.listener.socket_path).st_mode & 0o777
        self.assertEqual(mode, 0o660)


class SocketFolderTests(unittest.IsolatedAsyncioTestCase):
    async def test_world_writable_folder_is_refused(self):
        with tempfile.TemporaryDirectory(prefix="opencj-listener-test-") as directory:
            os.chmod(directory, 0o777)
            listener = OpenCJListener(None, str(Path(directory) / "events.sock"))
            with self.assertRaises(RuntimeError):
                await listener.start()

    async def test_other_file_at_socket_path_is_not_removed(self):
        with tempfile.TemporaryDirectory(prefix="opencj-listener-test-") as directory:
            socket_path = Path(directory) / "events.sock"
            socket_path.write_text("keep")
            listener = OpenCJListener(None, str(socket_path))
            with self.assertRaises(RuntimeError):
                await listener.start()
            self.assertEqual(socket_path.read_text(), "keep")


if __name__ == "__main__":
    unittest.main()
