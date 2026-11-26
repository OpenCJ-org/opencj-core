# Discord chat bridge

Relays chat between one game server and one Discord channel, and posts joins, leaves,
renames, finished runs and map changes. Installations made with `dev-tools/setup` set
this up for you; these notes are for running it by hand.

## Configuration

Create `config_<game>` (for example `config_cod4`) in the working directory:

```
token=<bot token>
guildid=<ID of the Discord server>
channelid=<ID of the channel the bot reads and writes>
# Optional: Discord users that players may ping from the game by typing @name.
mentionuserids=<user ID>,<user ID>
```

Blank lines and lines starting with `#` are ignored. Players can never ping
`@everyone`, `@here`, roles, or users missing from `mentionuserids`.

The bot needs the Message Content intent, and permission to view the channel and send messages.

## Socket

The bridge creates a Unix socket at the path in `OPENCJ_DISCORD_SOCKET`, and the game
server connects to the same path; a server without the variable does not use Discord.
Put the socket in a folder only the bridge and the game can use (for example mode 0770
with a shared group). The bridge refuses a folder every user can write to, and creates
the socket with mode 0660.

## Running

```
OPENCJ_DISCORD_SOCKET=/run/opencj-discord/events.sock python3 start.py cod4
```

The bridge logs to standard output.

## Tests

```
python3 -B dev-tools/scripts/test.py portable discord-socket
```
