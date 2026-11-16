# Alpha map pool: database catalogue

The database catalogue defines shared pool membership and mapper metadata.

Related design: [#203 map download authorization](../proposals/203-map-download-authorization.md).

## Existing table

Database/table: `openCJ_cod4.mapids`.

| Column | Type | Meaning / constraints |
| --- | --- | --- |
| `mapID` | `int` | Existing map identifier; auto-increment primary key |
| `mapname` | `char(128)` | Map asset name; required and unique |
| `releaseDate` | `date` | Historical release metadata; currently nullable in the schema |
| `inRotation` | `tinyint unsigned` | Required, default `0`; shared pool membership uses `1` |

There is no separate active-map or map-pool membership table in the inspected
schema. Reuse `inRotation` as the shared pool flag.

## Applied alpha pool

These are the applied values, in the database's actual column order. All map IDs
are preserved existing IDs. The previously empty dates now contain the historical
release metadata below.

| mapID | mapname | releaseDate | inRotation |
| ---: | --- | --- | ---: |
| 3975 | mp_dark | 2012-01-02 | 1 |
| 4163 | mp_cj_sky_bounce | 2013-04-24 | 1 |
| 4121 | mp_all_in | 2010-06-11 | 1 |
| 4100 | mp_bouncer_training | 2010-01-26 | 1 |
| 4640 | mp_futile_fixed | 2013-01-24 | 1 |
| 4141 | mp_blue2 | 2013-05-14 | 1 |
| 4202 | mp_descent_v2 | 2014-02-02 | 1 |
| 4529 | mp_to_the_moon | 2011-11-11 | 1 |
| 4280 | mp_galaxy | 2015-01-02 | 1 |
| 4402 | mp_mystic_v3 | 2013-10-25 | 1 |

## Related tables and stored authors

`openCJ_cod4.mappers` stores author identities:

| Column | Type | Meaning / constraints |
| --- | --- | --- |
| `mapperID` | `int` | Auto-increment primary key |
| `name` | `char(128)` | Required, unique mapper name |

`openCJ_cod4.mapMappers` links maps to their authors:

| Column | Type | Meaning / constraints |
| --- | --- | --- |
| `mapID` | `int` | Required foreign key to `mapids.mapID` |
| `mapperID` | `int` | Required foreign key to `mappers.mapperID` |

The pair (`mapID`, `mapperID`) is unique. Both foreign keys cascade on update
and delete. This is a many-to-many relationship: maps can have multiple mappers,
and a mapper can have multiple maps. Nine mapper rows and ten numeric links were
added to the previously empty author tables.

The following is a joined view of the applied data. The database allocated the
mapper IDs; `mapMappers` stores only the map and mapper IDs, not author strings.

| mapID | mapname | mapperID | Mapper name |
| ---: | --- | ---: | --- |
| 3975 | mp_dark | 447 | kie |
| 4163 | mp_cj_sky_bounce | 446 | SoBerries |
| 4121 | mp_all_in | 443 | all_in |
| 4100 | mp_bouncer_training | 445 | [TB]Mike |
| 4640 | mp_futile_fixed | 449 | pcbouncer |
| 4141 | mp_blue2 | 444 | Chucky. |
| 4202 | mp_descent_v2 | 448 | =.VaRtaZiaN.= |
| 4529 | mp_to_the_moon | 448 | =.VaRtaZiaN.= |
| 4280 | mp_galaxy | 450 | ZeeZ |
| 4402 | mp_mystic_v3 | 451 | Wez |

`[TB]Mike` is also credited as `MiKeY-B0Y` / `pMod.MiKeY-B0Y`.
Futile retains `pcbouncer` as its original mapper; the OpenCJ repair is maintenance
provenance. Script helpers and testers are not automatically promoted to map
co-authors.

Other existing tables with a direct `mapID` foreign key to `mapids`:

- `checkpoints`, `checkpointAreas` and `checkpointSectionColors`: checkpoint data.
- `playerRuns`: player run records.
- `demoRuns` and `demoClips`: demo/run and clip data.

None of those tables replaces the mapper relationship above.

## Date and author evidence

The [CoDJumper map catalogue](https://www.codjumper.com/maps/index2.php?game=cod4)
supplies the mapper names for Dark, Sky Bounce, All In, Bouncer Training, Blue2,
Descent v2, Moon and the original Futile. Galaxy's map script credits ZeeZ;
the original Mystic v3 walkthrough credits Wez.

Research evidence is retained under `local/alpha-map-metadata/` (ignored):
package manifests, archived forum HTML/text, video metadata, archive queries and
`package-http-metadata.json`. The latter records original response timestamps;
it is not a substitute for an announcement where one survives.

## Applied membership and catalogue behavior

Before the change, `mapids` held 459 maps: 457 enabled and two disabled.
Migration `server-db/migrations/015-alpha-map-pool.sql` kept the ten approved
maps enabled and disabled the other 447. The table still contains all 459 rows:
ten enabled, 449 disabled. Existing IDs and unrelated release metadata were
preserved. The migration is transactional and repeatable, but re-running it
deliberately resets membership to this initial pool; use ordinary
`mapids.inRotation` updates for subsequent pool maintenance.

The server now loads `mapids`, `mapMappers` and `mappers` with one joined query
at map initialization. It caches installed-map metadata and the enabled pool,
then publishes the complete cache after filesystem discovery finishes.
`alphaMapNames()` and its hard-coded fallback have been removed.

Regular map votes, exact/partial vote lookup, the map menu and its search,
`!maplist`, and automatic end-map votes all use the same enabled, installed
pool. Level-100 uber-admins retain access to every installed multiplayer map,
including maps without database rows. All roles still require actual map assets.
Authors and historical release dates populate the existing menu metadata.

A failed or empty database read grants no regular-player pool access. Installed
maps remain discoverable for uber-admins. Pool changes become visible at the next
map initialization; menus and vote checks do not issue per-map SQL queries.

The future #203 HTTP gateway can read this same membership flag and separately
apply the main-server active-map exception. HTTP download authorization remains
a documented design; it was not configured or implemented in this change.
