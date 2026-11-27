"""Game events and the wire format the game server uses to send them.

Each event is one line: the event number, then its fields, separated by FIELD_SEPARATOR
and ended by a line break. The game replaces separators and line breaks inside fields
with spaces before sending, so names and messages can contain any other character.
"""

from dataclasses import dataclass
import logging

from util import clean_game_text, get_clean_message, get_clean_name

LOG = logging.getLogger(__name__)

# ASCII unit separator: players cannot type it, unlike the ';' the protocol used before.
FIELD_SEPARATOR = '\x1f'

# These numbers match eGameEvent_t in server-ext/opencj_discord.cpp and the calls in
# server-gsc/opencj/discord.gsc. Never renumber them; only append.
EVENT_PLAYER_MESSAGE = 0
EVENT_MAP_STARTED = 1
EVENT_PLAYER_COUNT_CHANGED = 2
EVENT_PLAYER_JOINED = 3
EVENT_PLAYER_LEFT = 4
EVENT_RUN_FINISHED = 5
EVENT_PLAYER_RENAMED = 6
EVENT_SERVER_RECORD = 7
EVENT_CHALLENGE_COMPLETED = 8

MAP_NAME_MAX_CHARACTERS = 64
ROUTE_NAME_MAX_CHARACTERS = 64
RUN_TIME_MAX_CHARACTERS = 32
# "Standard FPS, checkpoints, elevators, halfbeat, TAS" is the longest label recordNotices builds.
RECORD_CATEGORY_MAX_CHARACTERS = 80
# Both boards together, for example "time: tied, 2 fewer RPGs; RPGs: tied, 0:02.000 faster".
RECORD_IMPROVEMENT_MAX_CHARACTERS = 120
# Enough of a rejected line to recognise it in the log without flooding it.
LOGGED_LINE_MAX_CHARACTERS = 80


@dataclass(frozen=True)
class PlayerMessageEvent:
    player_name: str
    message: str


@dataclass(frozen=True)
class MapStartedEvent:
    map_name: str


@dataclass(frozen=True)
class PlayerCountChangedEvent:
    player_count: int


@dataclass(frozen=True)
class PlayerJoinedEvent:
    player_name: str


@dataclass(frozen=True)
class PlayerLeftEvent:
    player_name: str


@dataclass(frozen=True)
class RunFinishedEvent:
    player_name: str
    run_id: int
    time_text: str
    map_name: str
    route_name: str


@dataclass(frozen=True)
class PlayerRenamedEvent:
    old_name: str
    new_name: str


@dataclass(frozen=True)
class ServerRecordEvent:
    """A finish that beat the server record of its exact category (time, RPGs or both)."""
    player_name: str
    map_name: str
    route_name: str
    category_label: str
    time_text: str
    rpg_count: int
    improvement_text: str


@dataclass(frozen=True)
class ChallengeCompletedEvent:
    """A challenge completed for the first time; time_limit_text is None when it has no limit."""
    player_name: str
    map_name: str
    route_label: str
    tier: int
    points: int
    time_limit_text: str | None


def clean_label(text, max_characters):
    """Map, route and time labels: readable text or None."""
    cleaned_label = clean_game_text(text)[:max_characters]
    if len(cleaned_label) == 0:
        return None
    return cleaned_label


def parse_player_message(fields):
    if len(fields) != 2:
        return None
    player_name = get_clean_name(fields[0])
    message = get_clean_message(fields[1])
    if player_name is None or message is None:
        return None
    return PlayerMessageEvent(player_name, message)


def parse_map_started(fields):
    if len(fields) != 1:
        return None
    map_name = clean_label(fields[0], MAP_NAME_MAX_CHARACTERS)
    if map_name is None:
        return None
    return MapStartedEvent(map_name)


def parse_player_count_changed(fields):
    if len(fields) != 1:
        return None
    player_count = int(fields[0])
    if player_count < 0:
        return None
    return PlayerCountChangedEvent(player_count)


def parse_player_joined(fields):
    if len(fields) != 1:
        return None
    player_name = get_clean_name(fields[0])
    if player_name is None:
        return None
    return PlayerJoinedEvent(player_name)


def parse_player_left(fields):
    if len(fields) != 1:
        return None
    player_name = get_clean_name(fields[0])
    if player_name is None:
        return None
    return PlayerLeftEvent(player_name)


def parse_run_finished(fields):
    if len(fields) != 5:
        return None
    player_name = get_clean_name(fields[0])
    run_id = int(fields[1])
    time_text = clean_label(fields[2], RUN_TIME_MAX_CHARACTERS)
    map_name = clean_label(fields[3], MAP_NAME_MAX_CHARACTERS)
    route_name = clean_label(fields[4], ROUTE_NAME_MAX_CHARACTERS)
    has_every_label = all(label is not None for label in (player_name, time_text, map_name, route_name))
    if not has_every_label:
        return None
    return RunFinishedEvent(player_name, run_id, time_text, map_name, route_name)


def parse_player_renamed(fields):
    if len(fields) != 2:
        return None
    old_name = get_clean_name(fields[0])
    new_name = get_clean_name(fields[1])
    if old_name is None or new_name is None or old_name == new_name:
        return None
    return PlayerRenamedEvent(old_name, new_name)


def parse_server_record(fields):
    if len(fields) != 7:
        return None
    player_name = get_clean_name(fields[0])
    map_name = clean_label(fields[1], MAP_NAME_MAX_CHARACTERS)
    route_name = clean_label(fields[2], ROUTE_NAME_MAX_CHARACTERS)
    category_label = clean_label(fields[3], RECORD_CATEGORY_MAX_CHARACTERS)
    time_text = clean_label(fields[4], RUN_TIME_MAX_CHARACTERS)
    rpg_count = int(fields[5])
    improvement_text = clean_label(fields[6], RECORD_IMPROVEMENT_MAX_CHARACTERS)
    labels = (player_name, map_name, route_name, category_label, time_text, improvement_text)
    has_every_label = all(label is not None for label in labels)
    if not has_every_label or rpg_count < 0:
        return None
    return ServerRecordEvent(player_name, map_name, route_name, category_label, time_text, rpg_count,
                             improvement_text)


def parse_challenge_completed(fields):
    if len(fields) != 6:
        return None
    player_name = get_clean_name(fields[0])
    map_name = clean_label(fields[1], MAP_NAME_MAX_CHARACTERS)
    route_label = clean_label(fields[2], ROUTE_NAME_MAX_CHARACTERS)
    tier = int(fields[3])
    points = int(fields[4])
    # An empty field means the challenge has no time limit.
    time_limit_text = clean_label(fields[5], RUN_TIME_MAX_CHARACTERS)
    has_every_label = all(label is not None for label in (player_name, map_name, route_label))
    if not has_every_label or tier < 1 or points < 0:
        return None
    return ChallengeCompletedEvent(player_name, map_name, route_label, tier, points, time_limit_text)


FIELD_PARSERS_BY_EVENT_NUMBER = {
    EVENT_PLAYER_MESSAGE: parse_player_message,
    EVENT_MAP_STARTED: parse_map_started,
    EVENT_PLAYER_COUNT_CHANGED: parse_player_count_changed,
    EVENT_PLAYER_JOINED: parse_player_joined,
    EVENT_PLAYER_LEFT: parse_player_left,
    EVENT_RUN_FINISHED: parse_run_finished,
    EVENT_PLAYER_RENAMED: parse_player_renamed,
    EVENT_SERVER_RECORD: parse_server_record,
    EVENT_CHALLENGE_COMPLETED: parse_challenge_completed,
}


def parse_game_event(line):
    """Turn one received line (without its line break) into an event, or None.

    Never raises: a malformed line from the game must not stop the listener.
    """
    event_number_text, _, field_text = line.partition(FIELD_SEPARATOR)
    try:
        event_number = int(event_number_text)
    except ValueError:
        LOG.warning('Ignoring game line without an event number: %r', line[:LOGGED_LINE_MAX_CHARACTERS])
        return None
    parse_fields = FIELD_PARSERS_BY_EVENT_NUMBER.get(event_number)
    if parse_fields is None:
        LOG.warning('Ignoring unknown game event %d', event_number)
        return None
    fields = field_text.split(FIELD_SEPARATOR)
    try:
        event = parse_fields(fields)
    except ValueError:
        event = None
    if event is None:
        LOG.warning('Ignoring malformed game event %d: %r', event_number, line[:LOGGED_LINE_MAX_CHARACTERS])
    return event
