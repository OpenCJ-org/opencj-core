"""Read-only database queries for the website. Every query mirrors an in-game rule where one exists."""

from dataclasses import dataclass

import pymysql
import pymysql.cursors

CONNECT_TIMEOUT_SECONDS = 5
READ_TIMEOUT_SECONDS = 30
MYSQL_ERROR_TABLE_ACCESS_DENIED = 1142
MYSQL_ERROR_TABLE_MISSING = 1146

# Same total as the in-game "Competitive - Top 10" (challenges.gsc competitiveSQL):
# only active challenges count, and equal totals are ordered by player ID.
CHALLENGE_RANKING_SQL = """
SELECT p.playerID AS playerID,
       p.playerName AS playerName,
       COALESCE(SUM(c.points), 0) AS points,
       COUNT(c.challengeKey) AS completedChallenges
FROM playerDisplayNames p
LEFT JOIN challengeCompletions a ON a.playerID = p.playerID
LEFT JOIN challenges c ON c.challengeKey = a.challengeKey AND c.active = 1
GROUP BY p.playerID, p.playerName
ORDER BY points DESC, p.playerID ASC
"""

ACTIVE_CHALLENGE_SQL = """
SELECT COUNT(*) AS challengeCount, COALESCE(SUM(points), 0) AS totalPoints
FROM challenges
WHERE active = 1
"""

POOL_MAPS_SQL = """
SELECT m.mapID AS mapID,
       m.mapname AS mapName,
       m.releaseDate AS releaseDate,
       GROUP_CONCAT(a.name ORDER BY a.name SEPARATOR ', ') AS mappers
FROM mapids m
LEFT JOIN mapMappers mm ON mm.mapID = m.mapID
LEFT JOIN mappers a ON a.mapperID = mm.mapperID
WHERE m.inRotation = 1
GROUP BY m.mapID, m.mapname, m.releaseDate
ORDER BY m.mapname ASC
"""

MAP_PLAYS_SQL = """
SELECT mapID, COUNT(*) AS plays, MAX(startedAt) AS lastPlayedAt
FROM mapPlays
GROUP BY mapID
"""

# Tutorial runs never count towards rankings (027-tutorial-runs.sql).
MAP_PLAYERS_SQL = """
SELECT mapID,
       COUNT(DISTINCT playerID) AS players,
       SUM(finishcpID IS NOT NULL) AS finishes
FROM playerRuns
WHERE tutorial = 0
GROUP BY mapID
"""

POOL_ROUTES_SQL = """
SELECT r.routeID AS routeID,
       r.mapID AS mapID,
       r.routeName AS routeName,
       r.routeType AS routeType,
       r.difficulty AS difficulty
FROM routes r
JOIN mapids m ON m.mapID = r.mapID
WHERE m.inRotation = 1
ORDER BY r.mapID ASC, r.routeType ASC, r.routeName ASC
"""

# Each player's best finish per route, with the in-game leaderboard's default
# filters (menus/leaderboard.gsc): no elevators, shortcuts, halfbeat or TAS,
# any FPS mode, no tutorial runs, and only active finish checkpoints.
# Equal times keep the oldest run, then the lowest checkpoint ID, as in game.
ROUTE_BESTS_SQL = """
SELECT best.playerID AS playerID,
       n.playerName AS playerName,
       best.routeID AS routeID,
       best.timePlayedMs AS timePlayedMs,
       best.loadCount AS loadCount,
       best.explosiveJumps AS explosiveJumps,
       best.finishedAt AS finishedAt,
       best.fpsMode AS fpsMode,
       best.runID AS runID,
       best.cpID AS cpID
FROM (
    SELECT pr.playerID,
           c.finishRouteID AS routeID,
           cs.timePlayed AS timePlayedMs,
           cs.loadCount,
           cs.explosiveJumps,
           pr.finishTimeStamp AS finishedAt,
           pr.FPSMode AS fpsMode,
           cs.runID,
           cs.cpID,
           ROW_NUMBER() OVER (
               PARTITION BY pr.playerID, c.finishRouteID
               ORDER BY cs.timePlayed ASC, cs.runID ASC, cs.cpID ASC
           ) AS playerRouteRank
    FROM checkpointStatistics cs
    JOIN checkpoints c ON c.cpID = cs.cpID
    JOIN playerRuns pr ON pr.runID = cs.runID
    JOIN mapids m ON m.mapID = pr.mapID
    WHERE c.finishRouteID IS NOT NULL
      AND c.retired = 0
      AND m.inRotation = 1
      AND pr.finishcpID IS NOT NULL
      AND pr.finishTimeStamp IS NOT NULL
      AND pr.ele = 0
      AND pr.anyPct = 0
      AND pr.hb = 0
      AND pr.hardTAS = 0
      AND pr.tutorial = 0
      AND pr.FPSMode IN ('125', 'mix', 'hax')
) best
JOIN playerDisplayNames n ON n.playerID = best.playerID
WHERE best.playerRouteRank = 1
"""


@dataclass
class DatabaseSnapshot:
    challenge_ranking: list
    active_challenge_count: int
    active_challenge_points: int
    pool_maps: list
    plays_by_map_id: dict  # None when the mapPlays table does not exist yet
    players_by_map_id: dict
    pool_routes: list
    route_bests: list


def connect(settings):
    """Open a read-only session; raise pymysql.MySQLError when the database is unreachable."""
    return pymysql.connect(
        host=settings.database_host,
        port=settings.database_port,
        user=settings.database_user,
        password=settings.database_password,
        database=settings.database_name,
        connect_timeout=CONNECT_TIMEOUT_SECONDS,
        read_timeout=READ_TIMEOUT_SECONDS,
        charset="utf8mb4",
        cursorclass=pymysql.cursors.DictCursor,
        autocommit=True,
    )


def _fetch_all(connection, sql):
    with connection.cursor() as cursor:
        cursor.execute(sql)
        return list(cursor.fetchall())


def _fetch_map_plays(connection):
    # Until migration 028 is applied there is no play data. Report that as
    # unknown rather than as zero plays. MySQL reports "access denied" instead
    # of "missing" when the account was granted before the table existed, so
    # both mean "not available yet"; tools/grant_web_access.py fixes the grant.
    try:
        rows = _fetch_all(connection, MAP_PLAYS_SQL)
    except (pymysql.err.ProgrammingError, pymysql.err.OperationalError) as error:
        error_code = error.args[0] if error.args else None
        if error_code in (MYSQL_ERROR_TABLE_MISSING, MYSQL_ERROR_TABLE_ACCESS_DENIED):
            return None
        raise
    return {row["mapID"]: row for row in rows}


def read_snapshot(connection):
    """Read everything one site build needs inside one consistent read-only transaction."""
    with connection.cursor() as cursor:
        cursor.execute("START TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY")
    try:
        challenge_totals = _fetch_all(connection, ACTIVE_CHALLENGE_SQL)[0]
        snapshot = DatabaseSnapshot(
            challenge_ranking=_fetch_all(connection, CHALLENGE_RANKING_SQL),
            active_challenge_count=int(challenge_totals["challengeCount"]),
            active_challenge_points=int(challenge_totals["totalPoints"]),
            pool_maps=_fetch_all(connection, POOL_MAPS_SQL),
            plays_by_map_id=_fetch_map_plays(connection),
            players_by_map_id={row["mapID"]: row for row in _fetch_all(connection, MAP_PLAYERS_SQL)},
            pool_routes=_fetch_all(connection, POOL_ROUTES_SQL),
            route_bests=_fetch_all(connection, ROUTE_BESTS_SQL),
        )
    finally:
        with connection.cursor() as cursor:
            cursor.execute("COMMIT")
    return snapshot
