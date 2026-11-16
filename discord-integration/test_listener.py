"""Exercise the real listener using a private temporary Unix socket."""

import asyncio
from pathlib import Path
import socket
import tempfile
import unittest

from opencj_listener import OpenCJListener


class DiscordListenerTests(unittest.IsolatedAsyncioTestCase):
    async def test_message_reaches_game_client(self):
        # Override only this instance before start() can unlink its socket path.
        with tempfile.TemporaryDirectory(prefix="opencj-listener-test-") as directory:
            listener = OpenCJListener(None, "test")
            listener.socket_path = str(Path(directory) / "events.sock")
            task = asyncio.create_task(listener.start())
            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            client.setblocking(False)
            loop = asyncio.get_running_loop()

            async def wait_for(predicate):
                while not predicate():
                    if task.done():
                        await task
                    await asyncio.sleep(0.01)

            try:
                await asyncio.wait_for(wait_for(lambda: listener.server is not None), 5)
                await loop.sock_connect(client, listener.socket_path)
                await asyncio.wait_for(wait_for(lambda: listener.client is not None), 5)
                await listener.on_discord_message("Test player", "Fixture message")
                message = await asyncio.wait_for(loop.sock_recv(client, 512), 5)
                self.assertEqual(message, b"^8[^7Discord^8]^7 Test player: Fixture message")
                client.close()
                await asyncio.wait_for(wait_for(lambda: listener.client is None), 5)
            finally:
                client.close()
                task.cancel()
                await asyncio.gather(task, return_exceptions=True)
                # Cancel any accepted-client handler still waiting after a failed assertion.
                handlers = [
                    pending
                    for pending in asyncio.all_tasks()
                    if pending is not asyncio.current_task()
                    and pending.get_coro().__qualname__ == "OpenCJListener.handle_client"
                ]
                for handler in handlers:
                    handler.cancel()
                await asyncio.gather(*handlers, return_exceptions=True)
                if listener.client is not None:
                    listener.client.close()
                if listener.server is not None:
                    listener.server.close()


if __name__ == "__main__":
    unittest.main()
