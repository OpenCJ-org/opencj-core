"""Exercise the real listener using a private temporary Unix socket."""

import asyncio
from pathlib import Path
import socket
import tempfile
import unittest

from opencj_listener import OpenCJListener

STATE_TIMEOUT_SECONDS = 5
STATE_POLL_SECONDS = 0.01


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


async def close_fixture(listener, client, existing_tasks):
    client.close()
    # IsolatedAsyncioTestCase owns this loop; all newly created tasks are fixture work.
    fixture_tasks = asyncio.all_tasks() - existing_tasks
    for task in fixture_tasks:
        task.cancel()
    await asyncio.gather(*fixture_tasks, return_exceptions=True)
    if listener.client is not None:
        listener.client.close()
    if listener.server is not None:
        listener.server.close()


class DiscordListenerTests(unittest.IsolatedAsyncioTestCase):
    async def test_message_reaches_game_client(self):
        # Set the private path before start() can unlink an existing socket.
        with tempfile.TemporaryDirectory(prefix="opencj-listener-test-") as directory:
            listener = OpenCJListener(None, "test")
            listener.socket_path = str(Path(directory) / "events.sock")
            existing_tasks = asyncio.all_tasks()
            listener_task = asyncio.create_task(listener.start())
            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            client.setblocking(False)
            loop = asyncio.get_running_loop()
            try:
                await asyncio.wait_for(
                    wait_for_listener_state(listener_task, lambda: listener.server is not None),
                    STATE_TIMEOUT_SECONDS,
                )
                await loop.sock_connect(client, listener.socket_path)
                await asyncio.wait_for(
                    wait_for_listener_state(listener_task, lambda: listener.client is not None),
                    STATE_TIMEOUT_SECONDS,
                )

                await listener.on_discord_message("Test player", "Fixture message")
                expected = b"^8[^7Discord^8]^7 Test player: Fixture message"
                received = await asyncio.wait_for(
                    receive_message(loop, client, len(expected)), STATE_TIMEOUT_SECONDS
                )
                self.assertEqual(received, expected)

                client.close()
                await asyncio.wait_for(
                    wait_for_listener_state(listener_task, lambda: listener.client is None),
                    STATE_TIMEOUT_SECONDS,
                )
            finally:
                await close_fixture(listener, client, existing_tasks)


if __name__ == "__main__":
    unittest.main()
