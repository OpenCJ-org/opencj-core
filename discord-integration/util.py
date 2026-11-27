"""Text cleaning for both directions of the bridge.

Game-bound text ends up inside a quoted server command, so it must not contain quotes,
backslashes or control characters. Discord-bound text is rendered as Markdown and can
mention people, so it is escaped and only explicitly allowed users can be pinged.
This module only uses the standard library so the portable tests can import it.
"""

import re

PLAYER_NAME_MIN_CHARACTERS = 2
PLAYER_NAME_MAX_CHARACTERS = 32
# CoD4 cuts chat lines at about 150 characters, and the "[Discord] name: " prefix uses part of that.
CHAT_MESSAGE_MAX_CHARACTERS = 128
TRUNCATION_MARKER = '...'

COLOR_CODE_PATTERN = re.compile(r'\^[0-9]')
CONTROL_CHARACTERS_PATTERN = re.compile(r'[\x00-\x1F\x7F]+')
# Quotes and backslashes would end or escape the quoted server command that carries chat text.
GAME_UNSAFE_CHARACTERS_PATTERN = re.compile(r'["\\]+')
# Characters Discord can treat as Markdown, a mention (@, <@id>), a channel, emoji or
# timestamp reference (<#id>, <:name:id>, <t:...>) or a masked link. Headings and lists
# only start a line, and bridge messages always start with the bot's own text.
DISCORD_MARKUP_PATTERN = re.compile(r'([\\*_~`|<>\[\]()@])')
CUSTOM_EMOJI_PATTERN = re.compile(r'<a?:([A-Za-z0-9_]{1,32}):[0-9]{15,22}>')
MENTION_REQUEST_PATTERN = re.compile(r'@([^\s@]{1,32})')


def strip_color_codes(text):
    return COLOR_CODE_PATTERN.sub('', text)


def replace_control_characters(text):
    return CONTROL_CHARACTERS_PATTERN.sub(' ', text)


def truncate(text, max_characters):
    """Cut text to max_characters, marking the cut so readers know something is missing."""
    if len(text) <= max_characters:
        return text
    return text[:max_characters - len(TRUNCATION_MARKER)] + TRUNCATION_MARKER


def clean_game_text(text):
    """Text from the game without colour codes or control characters."""
    without_colors = strip_color_codes(text)
    return replace_control_characters(without_colors).strip()


def get_clean_name(name):
    """A player name safe to show, or None when too little readable text remains."""
    cleaned_name = clean_game_text(name)
    if len(cleaned_name) < PLAYER_NAME_MIN_CHARACTERS:
        return None
    return cleaned_name[:PLAYER_NAME_MAX_CHARACTERS]


def get_clean_message(message):
    """A chat message safe to show, or None when it is empty after cleaning."""
    cleaned_message = clean_game_text(message)
    if len(cleaned_message) == 0:
        return None
    return truncate(cleaned_message, CHAT_MESSAGE_MAX_CHARACTERS)


def to_game_text(text):
    """Discord text reduced to what the game chat can show and carry safely.

    The game chat only renders ASCII, so other characters (including emoji) are dropped.
    """
    ascii_text = text.encode('ascii', 'ignore').decode('ascii')
    without_colors = strip_color_codes(ascii_text)
    without_controls = replace_control_characters(without_colors)
    without_unsafe = GAME_UNSAFE_CHARACTERS_PATTERN.sub("'", without_controls)
    return ' '.join(without_unsafe.split())


def replace_custom_emoji(text):
    """Show <:name:id> custom emoji as :name: in the game."""
    return CUSTOM_EMOJI_PATTERN.sub(r':\1:', text)


def escape_discord_markup(text):
    """Make text appear literally in Discord: no formatting, links or mentions."""
    return DISCORD_MARKUP_PATTERN.sub(r'\\\1', text)


def code_span(text):
    """Show a label in a code span; it cannot contain backticks, which would end the span."""
    return '``' + text.replace('`', "'") + '``'


def to_discord_text(text, mentionable_user_ids_by_name=None):
    """Escape game text for Discord, turning @name into a ping for allowed users only.

    mentionable_user_ids_by_name maps lowercase Discord names to user IDs. Anything else
    that looks like a mention, including @everyone, @here and <@id>, is shown as plain text.
    The caller must also restrict allowed_mentions to the same users, so a ping can never
    come from text that slipped past this function.
    """
    if not mentionable_user_ids_by_name:
        return escape_discord_markup(text)
    parts = []
    position = 0
    for request in MENTION_REQUEST_PATTERN.finditer(text):
        requested_name = request.group(1).lower()
        user_id = mentionable_user_ids_by_name.get(requested_name)
        if user_id is None:
            continue
        parts.append(escape_discord_markup(text[position:request.start()]))
        parts.append('<@' + str(user_id) + '>')
        position = request.end()
    parts.append(escape_discord_markup(text[position:]))
    return ''.join(parts)
