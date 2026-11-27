"""Discord side of the bridge: posts game events to one channel and relays its chat to the game."""

import asyncio
import logging
import time

import discord

from announcements import format_challenge_completed, format_server_record
from opencj_events import (ChallengeCompletedEvent, MapStartedEvent, PlayerCountChangedEvent, PlayerJoinedEvent,
                           PlayerLeftEvent, PlayerMessageEvent, PlayerRenamedEvent, RunFinishedEvent,
                           ServerRecordEvent)
from util import (CHAT_MESSAGE_MAX_CHARACTERS, PLAYER_NAME_MAX_CHARACTERS, PLAYER_NAME_MIN_CHARACTERS,
                  code_span, escape_discord_markup, replace_custom_emoji, to_discord_text, to_game_text,
                  truncate)

LOG = logging.getLogger(__name__)

# Game events wait here while Discord is slow or unreachable; beyond this the newest are dropped.
GAME_EVENT_QUEUE_MAX_EVENTS = 200
# Discord limits presence changes, and joins and leaves can come in bursts.
PRESENCE_UPDATE_INTERVAL_SECONDS = 15
# Allowed users can change their names, so look them up again now and then.
MENTION_NAMES_REFRESH_SECONDS = 600
UNKNOWN_DISCORD_NAME = 'Discord user'
RELAYED_MESSAGE_TYPES = (discord.MessageType.default, discord.MessageType.reply)



def game_safe_author_name(author):
    """The Discord author's name as the game can show it, falling back when nothing readable is left."""
    for candidate in (author.display_name, author.name):
        name = to_game_text(candidate)[:PLAYER_NAME_MAX_CHARACTERS]
        if len(name) >= PLAYER_NAME_MIN_CHARACTERS:
            return name
    return UNKNOWN_DISCORD_NAME


def game_text_for_message(message):
    """Discord message text as one game chat line: mentions as @name, emoji as :name:, files noted."""
    text = replace_custom_emoji(message.clean_content)
    if message.attachments:
        text = text + ' [attachment]'
    if message.stickers:
        text = text + ' [sticker]'
    game_text = to_game_text(text)
    return truncate(game_text, CHAT_MESSAGE_MAX_CHARACTERS)


class OpenCJDiscord(discord.Client):
    """Discord client for one channel, used by and using the game server listener."""

    def __init__(self, config):
        intents = discord.Intents.default()
        intents.message_content = True
        intents.messages = True
        # Pings are only possible for the configured users, whatever text reaches Discord.
        allowed_mentions = discord.AllowedMentions(
            everyone=False,
            roles=False,
            replied_user=False,
            users=[discord.Object(user_id) for user_id in config.mentionable_user_ids],
        )
        super().__init__(intents=intents, allowed_mentions=allowed_mentions)
        self.config = config
        self.gameserver = None
        self.channel = None
        self.map_name = None
        self.player_count = None
        self.shown_status = None
        self.mentionable_user_ids_by_name = {}
        self.mention_names_loaded_at = None
        self.dropped_event_count = 0
        self.game_events = asyncio.Queue(maxsize=GAME_EVENT_QUEUE_MAX_EVENTS)

    def set_gameserver(self, gameserver):
        self.gameserver = gameserver

    async def setup_hook(self):
        # One sender keeps channel messages in the order the game sent them.
        self.loop.create_task(self.send_game_events())
        self.loop.create_task(self.update_presence_periodically())

    def queue_game_event(self, event):
        """Called by the listener for each game event; never waits on Discord."""
        try:
            self.game_events.put_nowait(event)
        except asyncio.QueueFull:
            if self.dropped_event_count == 0:
                LOG.warning('Discord is not keeping up, dropping game events')
            self.dropped_event_count += 1

    async def on_ready(self):
        LOG.info('Logged in to Discord as %s', self.user)
        # A fresh gateway session starts without our presence, so show it again.
        self.shown_status = None

    async def get_chat_channel(self):
        if self.channel is None:
            channel = self.get_channel(self.config.channel_id)
            if channel is None:
                channel = await self.fetch_channel(self.config.channel_id)
            self.channel = channel
        return self.channel

    async def refresh_mention_names(self):
        """Map each allowed user's names (lowercase) to their ID so players can type @name."""
        if not self.config.mentionable_user_ids:
            return
        is_fresh = (self.mention_names_loaded_at is not None
                    and time.monotonic() - self.mention_names_loaded_at < MENTION_NAMES_REFRESH_SECONDS)
        if is_fresh:
            return
        guild = self.get_guild(self.config.guild_id)
        if guild is None:
            guild = await self.fetch_guild(self.config.guild_id)
        user_ids_by_name = {}
        for user_id in self.config.mentionable_user_ids:
            member = guild.get_member(user_id)
            if member is None:
                try:
                    member = await guild.fetch_member(user_id)
                except discord.NotFound:
                    LOG.warning('Mentionable user %d is not a member of the Discord server', user_id)
                    continue
            for name in (member.name, member.global_name, member.nick, member.display_name):
                if name:
                    user_ids_by_name[name.lower()] = user_id
        self.mentionable_user_ids_by_name = user_ids_by_name
        self.mention_names_loaded_at = time.monotonic()

    def format_game_event(self, event):
        """The channel message for a game event, or None when it only changes the presence."""
        if isinstance(event, PlayerMessageEvent):
            name = escape_discord_markup(event.player_name)
            text = to_discord_text(event.message, self.mentionable_user_ids_by_name)
            return '**' + name + '**: ' + text
        if isinstance(event, PlayerJoinedEvent):
            return '**' + escape_discord_markup(event.player_name) + '** has joined the game'
        if isinstance(event, PlayerLeftEvent):
            return '**' + escape_discord_markup(event.player_name) + '** has left the game'
        if isinstance(event, PlayerRenamedEvent):
            return ('**' + escape_discord_markup(event.old_name) + '** is now known as **'
                    + escape_discord_markup(event.new_name) + '**')
        if isinstance(event, RunFinishedEvent):
            return ('**' + escape_discord_markup(event.player_name) + '** finished '
                    + code_span(event.map_name + ' - ' + event.route_name) + ' in ' + code_span(event.time_text))
        if isinstance(event, ServerRecordEvent):
            return format_server_record(event)
        if isinstance(event, ChallengeCompletedEvent):
            return format_challenge_completed(event)
        if isinstance(event, MapStartedEvent):
            # The game repeats this after every reconnect; only a real change is announced.
            if event.map_name == self.map_name:
                return None
            self.map_name = event.map_name
            return '**Map changed to** ' + escape_discord_markup(self.map_name)
        if isinstance(event, PlayerCountChangedEvent):
            self.player_count = event.player_count
            return None
        LOG.warning('Unhandled game event: %r', event)
        return None

    async def send_game_events(self):
        """Post queued game events to the channel one at a time, for as long as the bot runs.

        A failed post is logged and skipped, so one Discord error never stops later events.
        """
        await self.wait_until_ready()
        while True:
            event = await self.game_events.get()
            if self.dropped_event_count:
                LOG.warning('Dropped %d game events while Discord was not keeping up', self.dropped_event_count)
                self.dropped_event_count = 0
            if isinstance(event, PlayerMessageEvent) and '@' in event.message:
                try:
                    await self.refresh_mention_names()
                except discord.DiscordException as error:
                    # Still post the message; @names just stay plain text this time.
                    LOG.warning('Could not look up mentionable users: %r', error)
            try:
                text = self.format_game_event(event)
                if text is not None:
                    channel = await self.get_chat_channel()
                    await channel.send(text)
            except discord.DiscordException as error:
                LOG.warning('Could not post game event to Discord: %r', error)

    def current_status(self):
        map_label = self.map_name if self.map_name else 'unknown'
        count_label = str(self.player_count) if self.player_count is not None else '?'
        return map_label + ' (' + count_label + ')'

    async def update_presence_periodically(self):
        """Show the current map and player count as the bot's activity, at most once per interval."""
        await self.wait_until_ready()
        while True:
            status = self.current_status()
            if status != self.shown_status and self.is_ready():
                try:
                    await self.change_presence(activity=discord.Game(name=status))
                    self.shown_status = status
                except discord.DiscordException as error:
                    LOG.warning('Could not update Discord presence: %r', error)
            await asyncio.sleep(PRESENCE_UPDATE_INTERVAL_SECONDS)

    def is_relayed_message(self, message):
        """Only people's ordinary messages in the configured channel go to the game."""
        if message.guild is None:
            return False
        if message.guild.id != self.config.guild_id or message.channel.id != self.config.channel_id:
            return False
        # Other bots and webhooks (including other bridges) could echo messages back and forth.
        if message.author.bot or message.webhook_id is not None:
            return False
        return message.type in RELAYED_MESSAGE_TYPES

    async def on_message(self, message):
        """Relay one Discord message to the game as a single cleaned chat line."""
        if not self.is_relayed_message(message):
            return
        if self.gameserver is None:
            LOG.info('Received a Discord message before the game server listener was set up')
            return
        text = game_text_for_message(message)
        if len(text) == 0:
            return
        await self.gameserver.on_discord_message(game_safe_author_name(message.author), text)
