# Alpha map pool: database catalogue

The database catalogue defines shared pool membership and mapper metadata.

Related design: [#203 map download authorization](../../proposals/map-download-authorization.md).

## Catalogue schema

Database/table: `openCJ_cod4.mapids`.

| Column | Type | Meaning / constraints |
| --- | --- | --- |
| `mapID` | `int` | Existing map identifier; auto-increment primary key |
| `mapname` | `char(128)` | Map asset name; required and unique |
| `releaseDate` | `date` | Historical release metadata; currently nullable in the schema |
| `inRotation` | `tinyint unsigned` | Required, default `0`; shared pool membership uses `1` |

There is no separate active-map or map-pool membership table in the inspected
schema. Reuse `inRotation` as the shared pool flag.

## Initial alpha pool

Migration [015-alpha-map-pool.sql](../../../server-db/migrations/015-alpha-map-pool.sql)
seeds the map names, release metadata and author credits below. It resolves
existing maps by name and preserves their IDs; missing maps receive IDs from
that database. **Numeric map and mapper IDs are installation-specific.**
The seed is not a live list of an operator's current enabled maps.

Approximate dates distinguish announcements, distribution dates and inferred
dates. They do not determine pool membership.

| Map name | Seed release date | Mapper |
| --- | --- | --- |
| mp_dark | 2012-01-02 | kie |
| mp_cj_sky_bounce | 2013-04-24 | SoBerries |
| mp_all_in | 2010-06-11 | all_in |
| mp_bouncer_training | 2010-01-26 | [TB]Mike |
| mp_futile_fixed | 2013-01-24 | pcbouncer |
| mp_blue2 | 2013-05-14 | Chucky. |
| mp_descent_v2 | 2014-02-02 | =.VaRtaZiaN.= |
| mp_to_the_moon | 2011-11-11 | =.VaRtaZiaN.= |
| mp_galaxy | 2015-01-02 | ZeeZ |
| mp_mystic_v3 | 2013-10-25 | Wez |

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
and a mapper can have multiple maps. The seed adds missing author/link rows
without requiring these tables to be empty.

Mapper names and public source attribution are recorded below. Numeric mapper IDs are allocated by each database and are not portable identifiers.

`[TB]Mike` is also credited as `MiKeY-B0Y` / `pMod.MiKeY-B0Y`.
Futile retains `pcbouncer` as its original mapper; the OpenCJ repair is maintenance
provenance. Script helpers and testers are not automatically promoted to map
co-authors.

Other existing tables with a direct `mapID` foreign key to `mapids`:

- `checkpoints`, `checkpointAreas` and `checkpointSectionColors`: checkpoint data.
- `playerRuns`: player run records.
- `demoRuns` and `demoClips`: demo/run and clip data.

None of those tables replaces the mapper relationship above.

## Map plays (028)

`openCJ_cod4.mapPlays` records one row per map session that a logged-in player
joined. The game inserts it when the first player of the session logs in, so
map loads on an empty server are not counted, and reconnecting players do not
add a second play. Gameplay may only insert rows. The website ranks maps by
these rows. Sessions before migration 028 were not recorded.

| Column | Type | Meaning / constraints |
| --- | --- | --- |
| `mapPlayID` | `int unsigned` | Auto-increment primary key |
| `mapID` | `int` | Required foreign key to `mapids.mapID` |
| `startedAt` | `timestamp` | When the session's first player logged in |

Implementation: [mapplays.gsc](../../../server-gsc/opencj/mapplays.gsc).

## Date and author evidence

The [CoDJumper map catalogue](https://www.codjumper.com/maps/index2.php?game=cod4)
supplies the mapper names for Dark, Sky Bounce, All In, Bouncer Training, Blue2,
Descent v2, Moon and the original Futile. Galaxy's map script credits ZeeZ;
the original Mystic v3 walkthrough credits Wez.

1. **mp_dark — 2012-01-02.** Kie's dated
   [release post](https://web.archive.org/web/20120105145238id_/http://codjumper.com/forums/viewtopic.php?f=16&t=14537)
   includes the map name, author and download. This supersedes the archive's
   later 8 January upload date.
2. **mp_cj_sky_bounce — 2013-04-24, approximate.** The
   [original CoDJumper package](https://www.codjumper.com/maps/cod4/mp_cj_sky_bounce.zip)
   has this distribution timestamp. Its map files were built on 15 April.
   No earlier release announcement was recovered.
3. **mp_all_in — 2010-06-11.** The
   [original package](https://www.codjumper.com/maps/cod4/mp_all_in.zip)
   has matching build/distribution dates. This is the best documented release
   date, rather than a recovered author announcement.
4. **mp_bouncer_training — 2010-01-26, approximate.** The
   [original package](https://www.codjumper.com/maps/cod4/mp_bouncer_training%20old.zip)
   was distributed then, with map files built on 21 January. The catalogue uses
   the first release of the map name. A later revision is available in the
   [final package](https://www.codjumper.com/maps/cod4/mp_bouncer_training.zip),
   built on 14 March and distributed around 14-15 March 2010. The
   [archived topic list](https://web.archive.org/web/20100711041114id_/http://www.codjumper.com:80/forums/viewforum.php?f=16)
   distinguishes the original and FINAL release topics, both by MiKeY-B0Y.
5. **mp_futile_fixed — 2013-01-24.** Use the original Futile release date,
   The original `mp_futile` was added to CoDJumper
   on this date, confirmed by the
   [catalogue publication post](https://web.archive.org/web/20130129041740id_/http://codjumper.com:80/forums/viewtopic.php?f=16&t=4925&p=173632).
   OpenCJ repair dates describe maintenance, not the original map release.
6. **mp_blue2 — 2013-05-14, approximate.** The
   [package](https://www.codjumper.com/maps/cod4/mp_blue2.zip) contains a main map
   built on this date. The
   [archived topic list](https://web.archive.org/web/20170916122706id_/http://www.codjumper.com/forums/viewforum.php?f=16&sid=2e6284ee76d22c89d5dde76d99ce313b&start=50)
   records Chucky's final reply in the release topic on the same date. An
   [18 May walkthrough](https://www.youtube.com/watch?v=za1traYVQOc) confirms
   availability shortly afterwards. The 5 June archive upload is later and is
   not used. The opening release post was not preserved in the located captures;
   14 May is an inference for this revision, not a verified first-release day.
7. **mp_descent_v2 — 2014-02-02.** The
   [launch walkthrough](https://www.youtube.com/watch?v=pAeCGO_Zv0o) and package
   build date agree. The
   [forum announcement](https://web.archive.org/web/20170916120141id_/http://www.codjumper.com/forums/viewtopic.php?f=16&t=16411&sid=2e6284ee76d22c89d5dde76d99ce313b)
   follows immediately. An earlier
   [author preview](https://www.youtube.com/watch?v=yOs7lDAbxTc) on 24 January
   explicitly says the map is still being finished; the later 13 February
   archive upload is not used as the release date.
8. **mp_to_the_moon — 2011-11-11.** The
   [original package](https://www.codjumper.com/maps/cod4/mp_to_the_moon.zip)
   was built and distributed that day. The
   [official walkthrough](https://www.youtube.com/watch?v=r_UpA1rKxcA)
   followed on 17 November and credits =.VaRtaZiaN.=.
9. **mp_galaxy — 2015-01-02.** The
   [original release announcement](https://board.3xp-clan.com/thread/2785-mp-galaxy-release/?postID=24393)
   is dated 2 January and provides a download. The forum account is now deleted;
   author credit is preserved in the map scripts as ZeeZ.
10. **mp_mystic_v3 — 2013-10-25.** The
    [archived announcement](https://web.archive.org/web/20170916114319id_/http://www.codjumper.com/forums/viewtopic.php?f=16&t=16247&sid=2e6284ee76d22c89d5dde76d99ce313b)
    describes the newly released map and points to its download via the
    [launch walkthrough](https://www.youtube.com/watch?v=Nt6eL095Wqc), which credits Wez.

## Membership and runtime behavior

Migration `server-db/migrations/015-alpha-map-pool.sql` establishes the initial ten-map pool while preserving existing map identities. Re-running it deliberately resets membership to that initial pool; use ordinary `mapids.inRotation` updates for subsequent maintenance.

The server loads `mapids`, `mapMappers` and `mappers` with one joined query
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
an unimplemented proposal, not an access-control service supplied by this repository.
