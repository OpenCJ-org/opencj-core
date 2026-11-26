"""Run the bridge for one game: python3 start.py <cod4|cod2>.

Reads config_<game> from the working directory and the socket path from OPENCJ_DISCORD_SOCKET.
"""

import asyncio
import logging
import sys

from bridge_config import load_config
from opencj_discord import OpenCJDiscord
from opencj_listener import OpenCJListener

LOG = logging.getLogger('opencj_discord_bridge')


async def run_bridge(config):
    """Run the Discord client and the game socket together until either one fails."""
    discord_client = OpenCJDiscord(config)
    listener = OpenCJListener(discord_client, config.socket_path)
    discord_client.set_gameserver(listener)
    LOG.info('Starting game server listener and Discord client')
    async with discord_client:
        # If either side stops, the whole bridge exits so its supervisor can restart it.
        await asyncio.gather(discord_client.start(config.token), listener.start())


def main():
    # stdout, not syslog: containers have no syslog socket, and Docker keeps stdout as the log.
    logging.basicConfig(level=logging.INFO, stream=sys.stdout,
                        format='%(asctime)s %(levelname)s %(name)s: %(message)s')
    if len(sys.argv) != 2:
        print('Usage: python3 start.py <cod4|cod2>', file=sys.stderr)
        return 2
    try:
        config = load_config(sys.argv[1])
    except (OSError, ValueError) as error:
        print('Configuration error: ' + str(error), file=sys.stderr)
        return 2
    asyncio.run(run_bridge(config))
    return 0


if __name__ == '__main__':
    sys.exit(main())
