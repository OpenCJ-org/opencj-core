"""Bridge configuration: the config_<game> file plus the socket path from the environment.

Only the standard library is used so the portable tests can import this module.
"""

from dataclasses import dataclass
import os
import re

SUPPORTED_GAMES = ('cod4', 'cod2')
SOCKET_PATH_ENVIRONMENT_VARIABLE = 'OPENCJ_DISCORD_SOCKET'
# Discord IDs ("snowflakes"); the same pattern as dev-tools/setup/configuration.py.
DISCORD_ID_PATTERN = re.compile(r'[0-9]{15,22}')
# Each allowed user's name is looked up on Discord, so keep the list small.
MENTIONABLE_USERS_MAX_COUNT = 25
# Linux limits Unix socket paths to 108 bytes including the terminating NUL.
SOCKET_PATH_MAX_BYTES = 107
REQUIRED_KEYS = ('token', 'guildid', 'channelid')
OPTIONAL_KEYS = ('mentionuserids',)


@dataclass(frozen=True)
class BridgeConfig:
    token: str
    guild_id: int
    channel_id: int
    mentionable_user_ids: tuple
    socket_path: str


def parse_discord_id(key, value):
    if not DISCORD_ID_PATTERN.fullmatch(value):
        raise ValueError(key + ' must be a Discord ID of 15-22 digits')
    return int(value)


def parse_mentionable_user_ids(value):
    """Comma-separated user IDs that players may ping from the game; empty means nobody."""
    user_ids = []
    for id_text in value.split(','):
        id_text = id_text.strip()
        if len(id_text) == 0:
            continue
        user_id = parse_discord_id('mentionuserids', id_text)
        if user_id not in user_ids:
            user_ids.append(user_id)
    if len(user_ids) > MENTIONABLE_USERS_MAX_COUNT:
        raise ValueError('mentionuserids allows at most ' + str(MENTIONABLE_USERS_MAX_COUNT) + ' users')
    return tuple(user_ids)


def read_config_values(text):
    """key=value lines; blank lines and lines starting with # are ignored."""
    values_by_key = {}
    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        line = raw_line.strip()
        if len(line) == 0 or line.startswith('#'):
            continue
        key, separator, value = line.partition('=')
        key = key.strip()
        if not separator:
            raise ValueError('Config line ' + str(line_number) + ' has no "="')
        if key not in REQUIRED_KEYS and key not in OPTIONAL_KEYS:
            raise ValueError('Unknown configuration option on line ' + str(line_number) + ': ' + key)
        if key in values_by_key:
            raise ValueError('Configuration option set twice: ' + key)
        values_by_key[key] = value.strip()
    for key in REQUIRED_KEYS:
        if not values_by_key.get(key):
            raise ValueError('Missing configuration option: ' + key)
    return values_by_key


def read_socket_path(environment):
    socket_path = environment.get(SOCKET_PATH_ENVIRONMENT_VARIABLE, '').strip()
    if not socket_path:
        raise ValueError(SOCKET_PATH_ENVIRONMENT_VARIABLE + ' must name the socket the game connects to')
    if not os.path.isabs(socket_path):
        raise ValueError(SOCKET_PATH_ENVIRONMENT_VARIABLE + ' must be an absolute path')
    if len(socket_path.encode()) > SOCKET_PATH_MAX_BYTES:
        raise ValueError(SOCKET_PATH_ENVIRONMENT_VARIABLE + ' is longer than a Unix socket path allows')
    return socket_path


def parse_config(text, environment):
    values_by_key = read_config_values(text)
    return BridgeConfig(
        token=values_by_key['token'],
        guild_id=parse_discord_id('guildid', values_by_key['guildid']),
        channel_id=parse_discord_id('channelid', values_by_key['channelid']),
        mentionable_user_ids=parse_mentionable_user_ids(values_by_key.get('mentionuserids', '')),
        socket_path=read_socket_path(environment),
    )


def load_config(game_name, environment=None):
    if game_name not in SUPPORTED_GAMES:
        raise ValueError('Unsupported game ' + repr(game_name) + '; supported: ' + ', '.join(SUPPORTED_GAMES))
    if environment is None:
        environment = os.environ
    with open('config_' + game_name, 'r', encoding='utf-8') as config_file:
        config_text = config_file.read()
    return parse_config(config_text, environment)
