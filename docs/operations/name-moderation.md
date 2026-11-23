# Maintain private name rules

The [name reference](../reference/gameplay/player-names.md) describes player
behavior, permissions and cooldowns. Operators supply their own moderation
policy. Rule entries, submitted names, exports and maintenance receipts remain
private, even when the stored terms are hashes.

## Current helper scope

[`server-db/tools/manage-name-rules.py`](../../server-db/tools/manage-name-rules.py)
currently targets the default development container `opencj-dev-db-1`.
Its `--database` option changes the schema, not the container; it does not yet
follow a custom Compose project or accept `--container`. Do not treat this
helper as a general remote-database administration tool.

The following commands run from `server-db` against that default development
installation. Run only the intended action after checking the target:

```sh
python3 tools/manage-name-rules.py --add
python3 tools/manage-name-rules.py --add --mode contains
python3 tools/manage-name-rules.py --exception RULE_ID
python3 tools/manage-name-rules.py --disable RULE_ID
python3 tools/manage-name-rules.py --list
```

Replace `RULE_ID` with the numeric rule ID. New terms and full-name exceptions
are read through a hidden terminal prompt; listing prints IDs and metadata only.
Use `--dry-run` when reviewing a proposed import or change. If using `--receipt`,
choose a private ignored location. Receipts are written with owner-only permissions.

Database commands stop waiting after three minutes. A timeout does not establish
whether a write committed; inspect the current rules before retrying.

## Optional seed source

`--seed` imports explicitly severe entries from the pinned English
[dsojevic/profanity-list](https://github.com/dsojevic/profanity-list) source at
commit `c27924319aa9bd6f917e3782b4f4b6604a50b652`, under its
[MIT license](https://github.com/dsojevic/profanity-list/blob/c27924319aa9bd6f917e3782b4f4b6604a50b652/LICENSE).
The helper preserves disabled rules and does not print or save the downloaded
plaintext list. It selects severity 4; many severity-3 values are unclassified
defaults. This is an optional starting policy, not a complete classification.

```sh
python3 tools/manage-name-rules.py --seed --dry-run
```

Normalization handles case, color codes, separators, common substitutions and
repeated letters. Whole-name and contained matches can have full-name exceptions.
Hashes avoid routinely displaying terms, but do not protect them against
dictionary guessing. Restrict database access and keep private policy data out
of Git and public support bundles.

## Apply policy changes

Use `!reloadnamerules` (admin level 60) or a normal map change to refresh the
server snapshot. A failed reload retains the last valid snapshot. A server
without a valid snapshot uses temporary regular names and waits before accepting
new preferred-name claims.

Rule changes do not silently rewrite existing preferred names. Moderators can
use `!frename` or `!resetprefname` at level 40 for the relevant account. Review
false positives through exceptions. Player names are checked locally and are
not sent to the seed provider or another moderation service.
