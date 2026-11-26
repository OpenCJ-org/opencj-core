---
applyTo: "server-gsc/opencj/permissions.gsc,server-gsc/opencj/moderation.gsc,server-gsc/opencj/commands_base.gsc,server-gsc/opencj/chat.gsc,server-gsc/opencj/playernames.gsc,server-gsc/opencj/login.gsc,server-ext/opencj_bans.*,server-db/migrations/**,docs/reference/permissions.md"
---

# Permissions: read the reference first

This is an active rule. Before changing permissions, bans, kicks, who may run a
command, or anything that checks `playerInformation.permissions`, read
[docs/reference/permissions.md](../../docs/reference/permissions.md) in full.

When a permission or group is added, removed, renamed or changes meaning, update all of
these in the same change, as that page's maintenance rule lists:

1. the permission table in `docs/reference/permissions.md`;
2. the catalogue in `server-gsc/opencj/permissions.gsc`, including permission groups
   and the group table in the reference;
3. the commands and checks that use it;
4. the SQL bit checks, through a new migration with `_<name>Bit` variables;
5. tests and other documents that mention it.

Never renumber or reuse a bit. Never make the uber bit grantable in the game.
Run `python3 -B dev-tools/scripts/test.py portable permissions-unit` before handing over.
