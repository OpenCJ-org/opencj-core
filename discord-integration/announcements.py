"""Channel messages for server records and challenge completions.

Kept apart from opencj_discord so the portable tests can check the wording without discord.py.
"""

from util import code_span, escape_discord_markup

RECORD_MARKER = '\U0001F3C6'  # trophy
CHALLENGE_MARKER = '\U0001F3AF'  # direct hit


def format_rpg_count(rpg_count):
    if rpg_count == 1:
        return '1 RPG'
    return str(rpg_count) + ' RPGs'


def format_server_record(event):
    """For example: <trophy> **Name** set a server record on ``mp_x - main`` (125 FPS, checkpoints):
    ``1:02.345`` with 3 RPGs (time: 0:00.512 faster)."""
    return (RECORD_MARKER + ' **' + escape_discord_markup(event.player_name) + '** set a server record on '
            + code_span(event.map_name + ' - ' + event.route_name)
            + ' (' + escape_discord_markup(event.category_label) + '): '
            + code_span(event.time_text) + ' with ' + format_rpg_count(event.rpg_count)
            + ' (' + escape_discord_markup(event.improvement_text) + ')')


def format_challenge_completed(event):
    """For example: <direct hit> **Name** completed the challenge ``mp_x - Hard`` (Tier 6, +60 pts,
    within 1:00:00)."""
    details = ['Tier ' + str(event.tier), '+' + str(event.points) + ' pts']
    if event.time_limit_text is not None:
        details.append('within ' + escape_discord_markup(event.time_limit_text))
    return (CHALLENGE_MARKER + ' **' + escape_discord_markup(event.player_name) + '** completed the challenge '
            + code_span(event.map_name + ' - ' + event.route_label) + ' (' + ', '.join(details) + ')')
