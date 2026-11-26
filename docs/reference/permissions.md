# Permissions

Each account has independent permission bits in `playerInformation.permissions`.
A player can hold any combination. There are no levels: a bit grants exactly what
its row says and nothing more.

> **Maintenance rule.** Read this page before changing anything about permissions.
> Adding, removing, renaming or changing a permission must update, in the same change:
>
> 1. this table;
> 2. the catalogue in `server-gsc/opencj/permissions.gsc` (`loadCatalogue`), including
>    any [group](#permission-groups) that should contain it;
> 3. the commands or checks that use it (`registerCommand(..., "<name>")`,
>    `hasPermission("<name>")`);
> 4. any SQL that checks the bit: add a **new migration** that redefines the function,
>    and use a `_<name>Bit` variable for the number (for example `_tempBanBit`);
> 5. the tests and any other document that mentions it.
>
> `python3 -B dev-tools/scripts/test.py portable permissions-unit` fails when this
> table, the group table, the catalogue, the command registrations and the SQL bit
> numbers disagree.
> Bit numbers are permanent: stored accounts keep them, so never renumber or reuse
> a bit. Retire a permission by marking its row unused. Bits 0-30 are usable.

## Permission table

| Bit | Name | Allows |
| --- | --- | --- |
| 0 | `uber` | Everything below, plus the uber-only abilities. Set in the database only. |
| 1 | `perms` | See other players' permissions; grant and revoke permissions you hold yourself. |
| 2 | `cpedit` | Create and edit checkpoint routes (`!checkpoint`, `!cp`). |
| 3 | `mute` | `!mute`, `!unmute`. |
| 4 | `names` | `!frename`, `!resetprefname`. |
| 5 | `maprestart` | `!maprestart`. |
| 6 | `mapdebug` | `!ent`, `!setorigin`, `!detectplat`. |
| 7 | `kick` | `!kick <player> <reason>`. |
| 8 | `tempban` | `!tempban <player> <30m\|12h\|7d> <reason>` (at most 7 days), `!untempban <player>`, `!bans`. |

### Uber-only abilities

Only `uber` (bit 0) can:

- `!permban <player> <reason>` and `!unpermban <player>`;
- `!reloadnamerules` and `!sqlstats`;
- vote for any installed map, not only the map pool, and vote without a cooldown;
- grant or revoke `perms`;
- act on another uber-admin. Nobody else can mute, rename, reset the name of, kick,
  ban or change the permissions of an uber-admin.

The uber bit itself can never be granted or revoked in the game. Set it with the
database owner's console (see [first administrator](../setup/server.md#first-administrator)):

```sql
UPDATE playerInformation SET permissions = permissions | 1 WHERE playerID = <id>;
```

The player must reconnect for a database change to take effect.

## Permission groups

A group is a named set of the permissions above. It is not stored: granting a group
sets all its member bits in one step, and revoking it clears them all, including
members that were also granted on their own. To grant or revoke a group without
uber, you must hold every member. A player who holds every member of a group is
shown with the group's name.

| Group | Aliases | Members |
| --- | --- | --- |
| `mod` | `moderation` | `mute`, `names`, `kick`, `tempban` |

Groups are defined in `loadCatalogue` in `server-gsc/opencj/permissions.gsc`; a group
may not contain `uber` or `perms`.

## Commands

| Command | Who | Effect |
| --- | --- | --- |
| `!permissions` (`!perms`) | everyone | Show your own permissions. |
| `!permissions help` | everyone | List every permission and group with a short description. |
| `!permissions <player>` | `perms` (or yourself) | Show a player's permissions. Offline players by playerID. |
| `!permissions grant <player> <name>` (`add`) | `perms` | Grant a permission or group you hold. |
| `!permissions revoke <player> <name>` (`remove`) | `perms` | Revoke a permission or group you hold. |
| `!playerid [player]` | everyone | Your playerID, or the IDs of matching online players. |

`<player>` is a playerID or part of an online player's name. A name must match one
player exactly or be the only partial match; otherwise the reply lists the matching
players with their IDs. Use `!playerid <name>` to tell players with the same name apart.

Online targets see their change at once. Every changed bit is recorded in
`permissionChanges` (actor, target, bit, granted, time); a group change records one
row per member that actually changed.

## Bans and kicks

- Every kick and ban needs a non-empty reason of at most 150 characters.
- A ban covers the account, plus the IP address and CoD4x player ID it last
  connected with (`playerInformation.lastIP` / `lastClientID`, updated at login).
- The engine refuses a banned IP address before the player's name reaches the game,
  so nothing about them is shown. A banned player ID is refused right after
  authentication, before the game state is sent. A banned account on a new address
  and player ID is refused at login, before the connect message.
- A new ban replaces the account's active bans. A temporary ban never replaces a
  permanent one. `!untempban` lifts only temporary bans; `!unpermban` only permanent ones.
- Bans are stored in `playerBans` and never deleted; lifted and expired rows stay as history.
- The engine's ban list is reloaded at every map start and after every ban change.
  Bans made on another server that shares the database apply there at its next map start.

## Database functions

The game asks the database to make every change; these functions repeat all the
rules above under row locks, so a stale or crafted request cannot bypass them.

| Function | Purpose |
| --- | --- |
| `playerHasPermission(player, bit)` | True for the bit or for uber. |
| `setPlayerPermissions(actor, target, mask, grant)` | Grant/revoke one or more bits and record each change; negative result codes are listed in migration 030. |
| `banPlayer(actor, target, seconds or NULL, reason)` | Create a temporary or permanent ban. |
| `liftPlayerBan(actor, target, permanent)` | Lift active temporary or permanent bans. |
| `resetPreferredNameByModerator(actor, target)` | Requires `names`; refuses uber targets for non-uber actors. |

Migration 029 converted the old levels: level 100 or higher became `uber`, and every
lower level was cleared.
