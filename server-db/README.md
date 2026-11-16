# OpenCJ database

This component contains schema exports, numbered migrations and administrative
tools. The export is a bootstrap input, not the complete current schema.
Do not apply individual feature migrations based on an old setup note.

- [Fresh development database](../docs/setup/development.md): empty-database
  bootstrap, complete migrations and generated configuration.
- [Database operations](../docs/operations/database.md): backups, tracked upgrades,
  runtime permissions and recovery.
- [Data model](../docs/reference/database/data-model.md), [route identity](../docs/reference/database/route-identity.md)
  and [save integrity](../docs/reference/database/save-integrity.md).
- [Challenges and shop](../docs/reference/gameplay/rewards.md): catalogue,
  competitive rank, earned currency and ownership.
- [Name-rule maintenance](../docs/operations/name-moderation.md): private policy,
  helper scope and source licensing.
- [Demo publication](../docs/reference/database/demo-publication.md) and
  [query performance](../docs/reference/database/query-performance.md).
- [Map catalogue](../docs/reference/maps/catalogue.md) and
  [checkpoint editing](../docs/reference/checkpoints/editor.md).
- [Country database updater](tools/geoip/README.md): manual imports and optional
  automation; [country lookup behavior](../docs/reference/ui/country-flags.md).

These linked pages are the maintained guides. Migration SQL records schema
changes; Git history records earlier documentation. Keep database dumps, player
records, moderation data, credentials and installation evidence private.
