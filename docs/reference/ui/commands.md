# Command browser

Use `!help` or `!commands` to open the command browser. Type to search
**command names and aliases only**. Exact matches come first, followed by
alphabetical partial matches. For example, `rp` puts `restoreposition` first
because `rp` is its alias; `doublerpgsstring` remains below it as a partial match.
An empty search lists all permitted commands alphabetically.

Backspace edits the search and Clear resets it. Select a command for its
aliases, description and existing usage text. The left arrows page through
commands; the right arrows page through long details. The red X or Escape
closes the menu. List and detail panels have separate, lighter backgrounds.

`!help <command>` stays a quick chat response. Aliases resolve to the primary
command, with the requested alias and primary name both shown. Lookup is
case-insensitive. Both help paths respect the same `minAdminLevel` used to
execute commands.

## Adding commands

`openCJ/commands_base.gsc` is the single registry. Register a command with
`registerCommand(name, help, func, minArgs, maxArgs, minAdminLevel, settingName)`
and add aliases with `addAlias(cmd, alias)`. Existing setting helpers also
register their command automatically. Include description and usage in the
existing `help` argument.

**There is no menu catalogue to update.** The browser reads `level.commands`
when opened and on search/navigation. Newly registered commands and aliases
appear on the next refresh, subject to the viewer's current admin level.
Aliases share their primary entry. Missing descriptions get a placeholder;
long help is wrapped and paginated without truncation. Changing rank through
`setAdminLevel` refreshes an open command menu; responses also recheck permissions.

The browser presents commands registered in the chat-command system, including
command-backed settings. Nested subcommand help remains separate (#153).
Alphabetical ordering and alias help also cover #154 and #152.

## Related menu cleanup

Commands, Maplist, Leaderboard and Runsboard use the common
`OPENCJ_CLOSE_BUTTON` red-X control, matching the shop's existing style.
The shop's genuine Back navigation remains alongside its existing red X.
The obsolete `!scoreboard` manual setup hint is removed; automatic Tab setup
and the scoreboard itself are unchanged.

## Implementation

- `server-gsc/opencj/commands_base.gsc`: live discovery, exact-match priority,
  alphabetical sorting, permissions, aliases and help entry points.
- `server-gsc/opencj/menus/commands.gsc`: search, selection, command/detail
  pagination and cached client-dvar updates.
- `client-mod/cod4/ui_mp/scriptmenus/opencj_commands.menu`: twelve command
  rows and eleven detail lines per page. Backspace uses CoD4 key code **127**.
- Initialization/player-connected hooks register the menu and listeners.
  The menu reports open/close state and uses the existing keyboard helper.
