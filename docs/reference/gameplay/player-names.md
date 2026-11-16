# Preferred record names and name moderation

Preferred names are optional account metadata linked by playerID. Record tables,
challenge standings, demos and clips use the preferred name when set, including
existing records. Live chat and the Tab scoreboard use the accepted regular name.

- `!prefname` shows the current choice and remaining cooldown.
- `!prefname set <name>` (or `!prefname <name>`) sets a unique, case-insensitive
  name of 3–15 printable ASCII characters, without color codes. Leading/trailing
  whitespace is removed and internal spaces are collapsed.
- `!prefname reset` restores fallback to the current account name.
- Preferred changes and resets share a one-hour database cooldown, across servers
  and reconnects. No-op requests do not consume it. A unique index and ordered
  name-namespace/account locking prevent simultaneous claims.
- Regular names have a 60-second cooldown after each accepted voluntary rename.
  The initial connection name does not start that timer. The first subsequent
  rename can therefore happen immediately. Reconnecting does not reset it:
  short-lived server memory retains the accepted name and timestamp by connection
  GUID, then OpenCJ account ID after login. A changed connection name during an
  active cooldown is restored to the accepted name. Expired entries are pruned.
  The game-scoped cache survives map initialization; process restarts clear it.
- The checkpoint comparison panel keeps the live regular name for its highlighted
  current-run row, including when spectating. Historical rows use preferred names,
  even when they belong to the same player. Setting/resetting a preferred name
  refreshes historical names in already visible panels without changing the live
  row's name, times, order or checkpoint comparison display duration.
- A regular name rejected by moderation is replaced by `Clown#` and four random
  digits, and the player gets a private explanation. Repeated rejected attempts
  reuse that connection's fallback. Requests during the regular-name cooldown
  retain the accepted name. Invalid preferred-name requests leave the old choice.
- `!frename <player> [name]` and `!resetprefname <playerID>` require moderator
  level 40. Resetting a preferred name starts its one-hour cooldown.
  `!reloadnamerules` requires admin level 60. Commands are registered in help.

## Open source and private policy data

The source contains the matcher, schema, management tool and harmless synthetic
tests. Actual matching rules live in the server database; raw terms are not
committed, echoed in rejection notices, or logged as name-command arguments.
Rules use hashes of normalized forms, so routine maintenance shows IDs and
metadata instead of terms. Hashing is not encryption or protection against
dictionary guessing; database access remains restricted.

The server checks names locally against a cached rule snapshot. Preferred names
are checked again inside the database write. Normalization handles case, color
codes, punctuation/separators, common letter/number substitutions and repeated
letters. Whole-name and contained rules have per-rule full-name exceptions.
A reload failure preserves the previous snapshot. No snapshot means unchecked
regular names receive a temporary fallback and new preferred-name claims wait.

Each operator supplies their own moderation policy. Review coverage and false positives, use exceptions where appropriate, and reset abusive preferred names missed by the filter. Updating rules does not silently rewrite existing account records.

See [name-rule maintenance](../../operations/name-moderation.md) for hidden
input, import/list/disable/exception commands, the helper's current container
limitation, pinned source and license.
No raw player names are sent to an external moderation service.
