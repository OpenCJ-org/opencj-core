"""Turn database rows, server status, releases and downloads into what the pages show."""

from dataclasses import dataclass, field

from .game_server import strip_color_codes

HOME_RANKING_SIZE = 10  # Matches the in-game Top 10.
RANKING_PAGE_SIZE = 100
HOME_POPULAR_MAP_COUNT = 5
LEADERBOARD_SIZE = 25
MAIN_ROUTE_TYPE = "normal"


@dataclass
class RankedPlayer:
    position: int
    player_id: int
    name: str
    points: int
    completed_challenges: int


@dataclass
class LeaderboardEntry:
    position: int
    player_id: int
    name: str
    time_ms: int
    load_count: int
    explosive_jumps: int
    fps_mode: str
    finished_at: object


@dataclass
class RouteBoard:
    route_id: int
    name: str
    route_type: str
    difficulty: object
    entries: list


@dataclass
class MapSummary:
    map_id: int
    name: str
    mappers: str
    release_date: object
    plays: object  # None when play counting is not available yet
    last_played_at: object
    players: int
    finishes: int
    routes: list = field(default_factory=list)
    download: object = None
    popularity_position: object = None


@dataclass
class PersonalBest:
    map_name: str
    route_name: str
    position: int
    time_ms: int
    fps_mode: str


@dataclass
class PlayerProfile:
    player_id: int
    name: str
    ranking: object  # RankedPlayer, or None without challenge points
    personal_bests: list


def assign_shared_positions(items, score_of):
    """Yield (position, item) pairs; equal scores share a position and the next score skips ahead.

    Items must already be sorted best first. This matches the in-game Top 10, where
    totals of 50, 40, 40, 30 are shown as positions 1, 2, 2, 4.
    """
    previous_score = None
    position = 0
    for index, item in enumerate(items):
        score = score_of(item)
        if score != previous_score:
            position = index + 1
            previous_score = score
        yield position, item


def build_challenge_ranking(ranking_rows):
    """Rank players by challenge points; players without points get no position."""
    ranked = []
    rows_with_points = [row for row in ranking_rows if int(row["points"]) > 0]
    for position, row in assign_shared_positions(rows_with_points, lambda row: int(row["points"])):
        ranked.append(RankedPlayer(
            position=position,
            player_id=int(row["playerID"]),
            name=strip_color_codes(row["playerName"]),
            points=int(row["points"]),
            completed_challenges=int(row["completedChallenges"]),
        ))
    return ranked


def build_home_top_ten(ranking_rows):
    """The first ten rows exactly as the in-game Top 10 lists them, including zero totals."""
    top_rows = ranking_rows[:HOME_RANKING_SIZE]
    top_ten = []
    for position, row in assign_shared_positions(top_rows, lambda row: int(row["points"])):
        top_ten.append(RankedPlayer(
            position=position,
            player_id=int(row["playerID"]),
            name=strip_color_codes(row["playerName"]),
            points=int(row["points"]),
            completed_challenges=int(row["completedChallenges"]),
        ))
    return top_ten


def _sorted_route_bests(route_rows):
    # Same tie-break as the in-game leaderboard: time, then oldest run, then checkpoint.
    return sorted(route_rows, key=lambda row: (int(row["timePlayedMs"]), int(row["runID"]), int(row["cpID"])))


def build_route_boards(pool_routes, route_bests):
    """Return (boards by map ID, all ranked entries by route ID) from each player's best runs."""
    bests_by_route_id = {}
    for row in route_bests:
        bests_by_route_id.setdefault(int(row["routeID"]), []).append(row)

    ranked_by_route_id = {}
    boards_by_map_id = {}
    for route in pool_routes:
        route_id = int(route["routeID"])
        sorted_rows = _sorted_route_bests(bests_by_route_id.get(route_id, []))
        entries = []
        for position, row in assign_shared_positions(sorted_rows, lambda row: int(row["timePlayedMs"])):
            entries.append(LeaderboardEntry(
                position=position,
                player_id=int(row["playerID"]),
                name=strip_color_codes(row["playerName"]),
                time_ms=int(row["timePlayedMs"]),
                load_count=int(row["loadCount"]),
                explosive_jumps=int(row["explosiveJumps"]),
                fps_mode=row["fpsMode"],
                finished_at=row["finishedAt"],
            ))
        ranked_by_route_id[route_id] = entries
        board = RouteBoard(
            route_id=route_id,
            name=route["routeName"],
            route_type=route["routeType"],
            difficulty=route["difficulty"],
            entries=entries[:LEADERBOARD_SIZE],
        )
        boards_by_map_id.setdefault(int(route["mapID"]), []).append(board)

    # Main routes first, then bonus and secret routes, each alphabetically.
    for boards in boards_by_map_id.values():
        boards.sort(key=lambda board: (board.route_type != MAIN_ROUTE_TYPE, board.route_type, board.name.lower()))
    return boards_by_map_id, ranked_by_route_id


def build_map_summaries(snapshot, boards_by_map_id, downloads_by_name):
    """Combine catalogue, play counts, run counts, routes and downloads for every pool map."""
    summaries = []
    for row in snapshot.pool_maps:
        map_id = int(row["mapID"])
        plays = None
        last_played_at = None
        if snapshot.plays_by_map_id is not None:
            play_row = snapshot.plays_by_map_id.get(map_id)
            plays = int(play_row["plays"]) if play_row else 0
            last_played_at = play_row["lastPlayedAt"] if play_row else None
        player_row = snapshot.players_by_map_id.get(map_id)
        summaries.append(MapSummary(
            map_id=map_id,
            name=row["mapName"],
            mappers=row["mappers"] or "Unknown",
            release_date=row["releaseDate"],
            plays=plays,
            last_played_at=last_played_at,
            players=int(player_row["players"]) if player_row else 0,
            finishes=int(player_row["finishes"] or 0) if player_row else 0,
            routes=boards_by_map_id.get(map_id, []),
            download=downloads_by_name.get(row["mapName"]),
        ))
    return summaries


def rank_maps_by_popularity(map_summaries):
    """Order maps by plays, then by distinct players; ties share a position."""
    def popularity(summary):
        return (summary.plays or 0, summary.players)

    def most_popular_first(summary):
        plays, players = popularity(summary)
        return (-plays, -players, summary.name)

    ordered = sorted(map_summaries, key=most_popular_first)
    for position, summary in assign_shared_positions(ordered, popularity):
        summary.popularity_position = position
    return ordered


def build_player_profiles(challenge_ranking, map_summaries, ranked_by_route_id):
    """Profiles for players with challenge points or at least one ranked finish."""
    profiles = {}
    for ranked_player in challenge_ranking:
        profiles[ranked_player.player_id] = PlayerProfile(
            ranked_player.player_id, ranked_player.name, ranked_player, [])

    for summary in map_summaries:
        for board in summary.routes:
            for entry in ranked_by_route_id.get(board.route_id, []):
                profile = profiles.get(entry.player_id)
                if profile is None:
                    profile = PlayerProfile(entry.player_id, entry.name, None, [])
                    profiles[entry.player_id] = profile
                profile.personal_bests.append(PersonalBest(
                    map_name=summary.name,
                    route_name=board.name,
                    position=entry.position,
                    time_ms=entry.time_ms,
                    fps_mode=entry.fps_mode,
                ))

    for profile in profiles.values():
        profile.personal_bests.sort(key=lambda best: (best.map_name, best.route_name.lower()))
    return profiles


def format_duration_ms(duration_ms):
    """Format a run time as m:ss.mmm, or h:mm:ss.mmm from one hour."""
    total_seconds, milliseconds = divmod(int(duration_ms), 1000)
    total_minutes, seconds = divmod(total_seconds, 60)
    hours, minutes = divmod(total_minutes, 60)
    if hours > 0:
        return f"{hours}:{minutes:02d}:{seconds:02d}.{milliseconds:03d}"
    return f"{minutes}:{seconds:02d}.{milliseconds:03d}"


def format_size_bytes(size_bytes):
    """Format a file size in MB with one decimal, or KB below one MB."""
    bytes_per_kilobyte = 1024
    bytes_per_megabyte = 1024 * 1024
    if size_bytes >= bytes_per_megabyte:
        return f"{size_bytes / bytes_per_megabyte:.1f} MB"
    return f"{max(1, round(size_bytes / bytes_per_kilobyte))} KB"
