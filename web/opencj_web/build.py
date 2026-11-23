"""Build the static site from live data and publish it atomically, once or on a fixed interval."""

import argparse
import datetime
import os
import shutil
import sys
import time
from pathlib import Path

import jinja2
import pymysql

from . import database
from . import downloads
from . import game_server
from . import releases
from . import site_model
from .config import load_settings

PACKAGE_DIR = Path(__file__).resolve().parent
TEMPLATES_DIR = PACKAGE_DIR / "templates"
STATIC_DIR = PACKAGE_DIR / "static"
STATUS_TIMEOUT_SECONDS = 2.0
# Keep the live build plus one older build, so a reader mid-request is never cut off.
KEPT_BUILD_COUNT = 2
BUILDS_FOLDER = "builds"
CURRENT_LINK = "current"
DOWNLOADS_FOLDER = "usermaps"


def log(message):
    timestamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    print(timestamp + " " + message, file=sys.stderr, flush=True)


def create_template_environment():
    environment = jinja2.Environment(
        loader=jinja2.FileSystemLoader(str(TEMPLATES_DIR)),
        autoescape=True,
        undefined=jinja2.StrictUndefined,
        trim_blocks=True,
        lstrip_blocks=True,
    )
    environment.filters["duration"] = site_model.format_duration_ms
    environment.filters["filesize"] = site_model.format_size_bytes
    return environment


def collect_site_data(settings):
    """Read every source for one build; raise when the database cannot be read."""
    connection = database.connect(settings)
    try:
        snapshot = database.read_snapshot(connection)
    finally:
        connection.close()

    server_status = game_server.query_status(
        settings.game_server_host, settings.game_server_port, STATUS_TIMEOUT_SECONDS)
    release_list, release_problems = releases.read_releases(settings.releases_dir)
    for problem in release_problems:
        log("Release note skipped: " + problem)

    pool_map_names = [row["mapName"] for row in snapshot.pool_maps]
    map_downloads = downloads.sync_pool_maps(
        pool_map_names, settings.usermaps_dir, settings.output_dir / DOWNLOADS_FOLDER)
    downloads_by_name = {download.map_name: download for download in map_downloads}

    challenge_ranking = site_model.build_challenge_ranking(snapshot.challenge_ranking)
    boards_by_map_id, ranked_by_route_id = site_model.build_route_boards(
        snapshot.pool_routes, snapshot.route_bests)
    map_summaries = site_model.build_map_summaries(snapshot, boards_by_map_id, downloads_by_name)
    maps_by_popularity = site_model.rank_maps_by_popularity(map_summaries)
    profiles = site_model.build_player_profiles(challenge_ranking, map_summaries, ranked_by_route_id)

    return {
        "generated_at": datetime.datetime.now(datetime.timezone.utc),
        "connect_address": settings.connect_address,
        "discord_invite_url": settings.discord_invite_url,
        "server": server_status,
        "releases": release_list,
        "top_ten": site_model.build_home_top_ten(snapshot.challenge_ranking),
        "challenge_ranking": challenge_ranking[:site_model.RANKING_PAGE_SIZE],
        "active_challenge_count": snapshot.active_challenge_count,
        "active_challenge_points": snapshot.active_challenge_points,
        "maps": map_summaries,
        "maps_by_popularity": maps_by_popularity,
        "popular_maps": maps_by_popularity[:site_model.HOME_POPULAR_MAP_COUNT],
        "plays_available": snapshot.plays_by_map_id is not None,
        "profiles": profiles,
        "downloads": map_downloads,
    }


def render_pages(environment, site_data):
    """Return {relative output path: html} for every page."""
    pages = {
        "index.html": ("home.html", {"page": "home"}),
        "releases/index.html": ("releases.html", {"page": "releases"}),
        "maps/index.html": ("maps.html", {"page": "maps"}),
        "rankings/index.html": ("rankings.html", {"page": "rankings"}),
        "downloads/index.html": ("downloads.html", {"page": "downloads"}),
        "guide/index.html": ("guide.html", {"page": "guide"}),
        "404.html": ("not_found.html", {"page": ""}),
    }
    for summary in site_data["maps"]:
        if downloads.is_safe_map_name(summary.name):
            pages["maps/" + summary.name + "/index.html"] = ("map.html", {"page": "maps", "map": summary})
    for profile in site_data["profiles"].values():
        pages["players/" + str(profile.player_id) + "/index.html"] = (
            "player.html", {"page": "rankings", "profile": profile})

    rendered = {}
    for output_path, (template_name, page_values) in pages.items():
        depth = output_path.count("/")
        values = dict(site_data)
        values.update(page_values)
        values["root"] = "../" * depth if depth > 0 else "./"
        rendered[output_path] = environment.get_template(template_name).render(**values)
    return rendered


def publish(output_dir, rendered_pages):
    """Write a complete new build, then switch the 'current' link to it in one rename."""
    builds_dir = output_dir / BUILDS_FOLDER
    builds_dir.mkdir(parents=True, exist_ok=True)
    build_name = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    build_dir = builds_dir / build_name
    build_dir.mkdir()

    for relative_path, html in rendered_pages.items():
        page_path = build_dir / relative_path
        page_path.parent.mkdir(parents=True, exist_ok=True)
        page_path.write_text(html, encoding="utf-8")
    shutil.copytree(STATIC_DIR, build_dir / "static")

    # The link target is relative so the web server can mount the same volume elsewhere.
    temporary_link = output_dir / (CURRENT_LINK + ".next")
    if temporary_link.is_symlink() or temporary_link.exists():
        temporary_link.unlink()
    os.symlink(Path(BUILDS_FOLDER) / build_name, temporary_link)
    os.replace(temporary_link, output_dir / CURRENT_LINK)

    old_builds = sorted(path for path in builds_dir.iterdir() if path.is_dir())
    for old_build in old_builds[:-KEPT_BUILD_COUNT]:
        shutil.rmtree(old_build)


def build_once(settings, environment):
    site_data = collect_site_data(settings)
    publish(settings.output_dir, render_pages(environment, site_data))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--once", action="store_true", help="Build one time and exit")
    options = parser.parse_args()

    try:
        settings = load_settings()
    except ValueError as error:
        log("Configuration error: " + str(error))
        return 2
    environment = create_template_environment()

    while True:
        started = time.monotonic()
        try:
            build_once(settings, environment)
            log("Site published")
        except (pymysql.MySQLError, OSError, ValueError, RuntimeError, jinja2.TemplateError) as error:
            # Keep serving the previous build; the next cycle tries again.
            log("Build failed, previous site kept: " + type(error).__name__ + ": " + str(error))
            if options.once:
                return 1
        if options.once:
            return 0
        elapsed_seconds = time.monotonic() - started
        time.sleep(max(1.0, settings.rebuild_interval_seconds - elapsed_seconds))


if __name__ == "__main__":
    sys.exit(main())
