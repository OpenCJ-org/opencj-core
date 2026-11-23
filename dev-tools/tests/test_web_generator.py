"""Unit tests for the website generator parts that need no database, game server or Jinja2."""

import datetime
import os
import sys
import tempfile
import unittest
from pathlib import Path

WEB_DIR = Path(__file__).resolve().parents[2] / "web"
sys.path.insert(0, str(WEB_DIR))

from opencj_web import config  # noqa: E402
from opencj_web import downloads  # noqa: E402
from opencj_web import game_server  # noqa: E402
from opencj_web import releases  # noqa: E402
from opencj_web.site_model import assign_shared_positions  # noqa: E402
from opencj_web.site_model import format_duration_ms  # noqa: E402


class StatusReplyTests(unittest.TestCase):
    def test_reads_map_and_counts_player_lines(self):
        reply = (
            game_server.STATUS_REPLY_HEADER
            + b"\\sv_maxclients\\24\\mapname\\mp_galaxy\\g_gametype\\cj\n"
            + b'0 48 "^1kes^7trel"\n'
            + b'0 999 "bot"\n'
        )
        status = game_server.parse_status_reply(reply)
        self.assertEqual(status.map_name, "mp_galaxy")
        self.assertEqual(status.player_count, 2)
        self.assertEqual(status.max_players, 24)

    def test_empty_server_has_zero_players(self):
        reply = game_server.STATUS_REPLY_HEADER + b"\\mapname\\mp_dark\\sv_maxclients\\16\n"
        self.assertEqual(game_server.parse_status_reply(reply).player_count, 0)

    def test_rejects_other_packets(self):
        with self.assertRaises(ValueError):
            game_server.parse_status_reply(b"\xff\xff\xff\xffinfoResponse\n\\mapname\\x")

    def test_rejects_reply_without_map(self):
        with self.assertRaises(ValueError):
            game_server.parse_status_reply(game_server.STATUS_REPLY_HEADER + b"\\sv_maxclients\\24\n")

    def test_strips_color_codes(self):
        self.assertEqual(game_server.strip_color_codes("^1Open^7CJ"), "OpenCJ")


class ReleaseNoteTests(unittest.TestCase):
    NOTE = (
        "# Challenges arrive\n"
        "Version: 0.9.0 beta\n"
        "Released: 2026-11-20\n"
        "\n"
        "A short summary\n"
        "over two lines.\n"
        "\n"
        "## Gameplay\n"
        "- New `!fov` values\n"
        "- Tutorial mode\n"
    )

    def test_reads_header_and_blocks(self):
        release = releases.parse_release(self.NOTE, "0.9.0.md")
        self.assertEqual(release.title, "Challenges arrive")
        self.assertEqual(release.version, "0.9.0 beta")
        self.assertEqual(release.released_on, datetime.date(2026, 11, 20))
        self.assertEqual(release.slug, "0-9-0-beta")
        kinds = [block.kind for block in release.blocks]
        self.assertEqual(kinds, ["paragraph", "heading", "list"])
        self.assertEqual(release.blocks[0].segments[0].text, "A short summary over two lines.")

    def test_marks_inline_code(self):
        release = releases.parse_release(self.NOTE, "0.9.0.md")
        first_item = release.blocks[2].items[0]
        self.assertEqual([(part.text, part.is_code) for part in first_item],
                         [("New ", False), ("!fov", True), (" values", False)])

    def test_rejects_bad_date_with_file_name(self):
        broken = self.NOTE.replace("2026-11-20", "20 Nov 2026")
        with self.assertRaisesRegex(ValueError, "broken.md"):
            releases.parse_release(broken, "broken.md")

    def test_reads_folder_newest_first_and_reports_bad_files(self):
        with tempfile.TemporaryDirectory() as folder:
            folder_path = Path(folder)
            (folder_path / "README.md").write_text("# Format description\n")
            (folder_path / "old.md").write_text(self.NOTE.replace("2026-11-20", "2026-10-01").replace("0.9.0", "0.8.0"))
            (folder_path / "new.md").write_text(self.NOTE)
            (folder_path / "bad.md").write_text("no header\n")
            release_list, problems = releases.read_releases(folder_path)
        self.assertEqual([release.version for release in release_list], ["0.9.0 beta", "0.8.0 beta"])
        self.assertEqual(len(problems), 1)
        self.assertIn("bad.md", problems[0])


class ReleasePreviewTests(unittest.TestCase):
    NOTE = (
        "# Title\nVersion: 1.0\nReleased: 2026-11-20\n\n"
        "Summary.\n\n## First\n- a\n- b\n- c\n\n## Second\n- d\n- e\n"
    )

    def test_short_note_is_shown_whole(self):
        release = releases.parse_release(self.NOTE, "note.md")
        blocks, shortened = releases.preview_blocks(release.blocks, 20)
        self.assertFalse(shortened)
        self.assertEqual(len(blocks), len(release.blocks))

    def test_long_list_is_cut_between_items(self):
        release = releases.parse_release(self.NOTE, "note.md")
        blocks, shortened = releases.preview_blocks(release.blocks, 4)
        self.assertTrue(shortened)
        self.assertEqual([block.kind for block in blocks], ["paragraph", "heading", "list"])
        self.assertEqual(len(blocks[-1].items), 2)

    def test_never_ends_on_a_lone_heading(self):
        release = releases.parse_release(self.NOTE, "note.md")
        blocks, shortened = releases.preview_blocks(release.blocks, 6)
        self.assertTrue(shortened)
        self.assertNotEqual(blocks[-1].kind, "heading")


class CurrentVersionNoteTests(unittest.TestCase):
    """The version in VERSION must have a release note (see the release notes rule)."""

    def test_current_version_has_a_release_note(self):
        core_root = WEB_DIR.parent
        version = (core_root / "VERSION").read_text().strip()
        release_list, problems = releases.read_releases(core_root / "docs" / "releases")
        self.assertEqual(problems, [], "Unreadable release notes")
        versions = [release.version for release in release_list]
        self.assertIn(version, versions,
                      "Add docs/releases/" + version + ".md with 'Version: " + version + "'")


class SharedPositionTests(unittest.TestCase):
    def test_equal_scores_share_and_next_skips(self):
        scores = [50, 40, 40, 30]
        positions = [position for position, _ in assign_shared_positions(scores, lambda score: score)]
        self.assertEqual(positions, [1, 2, 2, 4])

    def test_formats_run_times(self):
        self.assertEqual(format_duration_ms(83456), "1:23.456")
        self.assertEqual(format_duration_ms(3723004), "1:02:03.004")


class DiscordInviteSettingTests(unittest.TestCase):
    def read_with(self, value):
        previous = os.environ.get("WEB_DISCORD_INVITE_URL")
        os.environ["WEB_DISCORD_INVITE_URL"] = value
        try:
            return config.read_discord_invite_url()
        finally:
            if previous is None:
                del os.environ["WEB_DISCORD_INVITE_URL"]
            else:
                os.environ["WEB_DISCORD_INVITE_URL"] = previous

    def test_empty_setting_hides_the_button(self):
        self.assertEqual(self.read_with(""), "")

    def test_accepts_invite_links(self):
        self.assertEqual(self.read_with("https://discord.gg/abc123"), "https://discord.gg/abc123")
        self.assertEqual(self.read_with("https://discord.com/invite/abc-123"), "https://discord.com/invite/abc-123")

    def test_rejects_other_addresses(self):
        for value in ("http://discord.gg/abc", "https://example.com/abc", "https://discord.gg/abc\"onclick"):
            with self.assertRaises(ValueError):
                self.read_with(value)


class DownloadSyncTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name)
        self.usermaps = root / "usermaps"
        self.downloads = root / "downloads"
        for map_name in ("mp_pool", "mp_private"):
            (self.usermaps / map_name).mkdir(parents=True)
            (self.usermaps / map_name / (map_name + ".ff")).write_bytes(b"fastfile")
        (self.usermaps / "mp_pool" / "notes.txt").write_text("not a map file")

    def tearDown(self):
        self.temporary.cleanup()

    def test_publishes_only_pool_map_files(self):
        results = downloads.sync_pool_maps(["mp_pool"], self.usermaps, self.downloads)
        self.assertEqual([download.map_name for download in results], ["mp_pool"])
        self.assertEqual(sorted(os.listdir(self.downloads)), ["mp_pool"])
        self.assertEqual(sorted(os.listdir(self.downloads / "mp_pool")), ["mp_pool.ff"])

    def test_published_copies_are_world_readable(self):
        source_file = self.usermaps / "mp_pool" / "mp_pool.ff"
        source_file.chmod(0o640)
        downloads.sync_pool_maps(["mp_pool"], self.usermaps, self.downloads)
        published_mode = (self.downloads / "mp_pool" / "mp_pool.ff").stat().st_mode & 0o777
        self.assertEqual(published_mode, downloads.PUBLISHED_FILE_MODE)

    def test_removes_maps_that_left_the_pool(self):
        downloads.sync_pool_maps(["mp_pool", "mp_private"], self.usermaps, self.downloads)
        downloads.sync_pool_maps(["mp_pool"], self.usermaps, self.downloads)
        self.assertEqual(sorted(os.listdir(self.downloads)), ["mp_pool"])

    def test_missing_map_is_listed_as_unavailable(self):
        results = downloads.sync_pool_maps(["mp_missing"], self.usermaps, self.downloads)
        self.assertFalse(results[0].is_available)
        self.assertEqual(os.listdir(self.downloads), [])

    def test_rejects_path_like_map_names(self):
        with self.assertRaises(ValueError):
            downloads.sync_pool_maps(["../mp_pool"], self.usermaps, self.downloads)

    def test_updates_a_changed_file(self):
        downloads.sync_pool_maps(["mp_pool"], self.usermaps, self.downloads)
        source_file = self.usermaps / "mp_pool" / "mp_pool.ff"
        source_file.write_bytes(b"new fastfile contents")
        downloads.sync_pool_maps(["mp_pool"], self.usermaps, self.downloads)
        self.assertEqual((self.downloads / "mp_pool" / "mp_pool.ff").read_bytes(), b"new fastfile contents")


if __name__ == "__main__":
    unittest.main()
