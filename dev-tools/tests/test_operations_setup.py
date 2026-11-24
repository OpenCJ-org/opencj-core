"""Operational setup features: retention, downloads, HTTPS routing, prompts, shared assets, firewall, maps."""

from datetime import datetime, timedelta, timezone
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'setup'))
import configuration
import firewall
import install
import maintenance
import maps
import migration
import source
import website
from operations import save_json


def backup_name(moment):
    return moment.strftime('%Y%m%dT%H%M%SZ') + '.sql.gz'


class OffsiteRetentionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.now = datetime(2027, 6, 1, 3, 30, tzinfo=timezone.utc)

    def make_backups(self, sender, days_ago, size_bytes=10):
        folder = self.directory / sender
        folder.mkdir(exist_ok=True)
        for days in days_ago:
            (folder / backup_name(self.now - timedelta(days=days))).write_bytes(b'x' * size_bytes)

    def remaining(self, sender):
        return sorted(path.name for path in (self.directory / sender).iterdir())

    def test_tiered_retention_keeps_recent_daily_then_weekly_then_monthly(self):
        # One backup per day for 400 days.
        self.make_backups('main-eu', range(400))
        with patch.object(maintenance, 'datetime', wraps=datetime) as clock:
            clock.now.return_value = self.now
            maintenance.run_receiver_retention(self.directory, 50)
        kept = [self.now - datetime.strptime(name[:15], '%Y%m%dT%H%M%S').replace(tzinfo=timezone.utc)
                for name in self.remaining('main-eu')]
        daily = [age for age in kept if age.days <= maintenance.RECEIVER_DAILY_DAYS]
        older = [age for age in kept if age.days > maintenance.RECEIVER_DAILY_DAYS]
        self.assertEqual(len(daily), maintenance.RECEIVER_DAILY_DAYS + 1)
        self.assertLessEqual(len(older), maintenance.RECEIVER_WEEKLY_WEEKS + maintenance.RECEIVER_MONTHLY_MONTHS)
        self.assertTrue(all(age.days <= maintenance.RECEIVER_MONTHLY_MONTHS * 31 for age in kept),
                        'Backups older than a year must be removed')

    def test_size_cap_removes_oldest_but_never_the_newest_per_sender(self):
        # Scale the unit down (1 "GiB" = 100 bytes) so the test needs no real gigabytes.
        self.make_backups('main-eu', range(14), size_bytes=25)
        self.make_backups('main-us', range(10), size_bytes=25)
        with patch.object(maintenance, 'datetime', wraps=datetime) as clock, \
                patch.object(maintenance, 'GIB', 100):
            clock.now.return_value = self.now
            maintenance.run_receiver_retention(self.directory, 4)
        for sender in ('main-eu', 'main-us'):
            self.assertGreaterEqual(len(self.remaining(sender)), maintenance.RECEIVER_MIN_KEPT_BACKUPS,
                                    sender + ' lost one of its newest backups')
        total_files = len(self.remaining('main-eu')) + len(self.remaining('main-us'))
        self.assertEqual(total_files, 16, 'Expected the 4 "GiB" cap to hold exactly sixteen 0.25 "GiB" backups')
        self.assertIn(backup_name(self.now), self.remaining('main-eu'), 'The newest backup must survive')

    def test_foreign_files_are_left_alone(self):
        self.make_backups('main-eu', range(3))
        (self.directory / 'main-eu' / 'notes.txt').write_text('operator file')
        maintenance.run_receiver_retention(self.directory, 50)
        self.assertIn('notes.txt', self.remaining('main-eu'))


class DownloadAndWebsiteTests(unittest.TestCase):
    def test_download_modes_set_matching_server_settings(self):
        website_mode = install.download_cvars({'mode': 'website', 'base_url': 'http://opencj.org'})
        self.assertEqual((website_mode['sv_allowDownload'], website_mode['sv_wwwDownload'],
                          website_mode['sv_wwwBaseURL']), ('1', '1', 'http://opencj.org'))
        in_game = install.download_cvars({'mode': 'in-game'})
        self.assertEqual((in_game['sv_allowDownload'], in_game['sv_wwwDownload']), ('1', '0'))
        off = install.download_cvars({'mode': 'off'})
        self.assertEqual((off['sv_allowDownload'], off['sv_wwwDownload']), ('0', '0'))

    def test_download_urls_must_be_plain_http_hosts(self):
        for url in ('https://opencj.org', 'http://opencj.org/usermaps', 'ftp://x'):
            with self.subTest(url=url), self.assertRaises(ValueError):
                configuration.validate_download_url(url)
        self.assertEqual(configuration.validate_download_url('http://eu.opencj.org:8080'), 'http://eu.opencj.org:8080')

    def test_only_map_downloads_stay_on_plain_http(self):
        text = website.caddyfile({'domain': 'opencj.org', 'acme_email': ''})
        https_site, http_site = text.split('http://opencj.org {')
        self.assertIn('opencj.org {', https_site)
        self.assertIn('reverse_proxy httpd:8080', https_site)
        self.assertIn('handle /usermaps/*', http_site)
        self.assertIn('redir https://{host}{uri} permanent', http_site)

    def test_website_domain_and_invite_validation(self):
        for domain in ('http://opencj.org', 'OpenCJ.org', 'opencj'):
            with self.subTest(domain=domain), self.assertRaises(ValueError):
                website.validate_domain(domain)
        self.assertEqual(website.validate_invite('disabled'), '')
        with self.assertRaises(ValueError):
            website.validate_invite('https://example.com/invite')


class PromptTests(unittest.TestCase):
    def test_invalid_answers_are_asked_again_instead_of_aborting(self):
        answers = iter(['abc', '99', '16'])
        with patch('builtins.input', lambda label: next(answers)), patch('builtins.print'):
            self.assertEqual(configuration.ask_int('Player slots', 32, 1, 32), 16)

    def test_choices_and_defaults(self):
        answers = iter(['maybe', ''])
        with patch('builtins.input', lambda label: next(answers)), patch('builtins.print'):
            self.assertTrue(configuration.ask_yes_no('Continue?', True))


class SharedAssetBundleTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.bundle = Path(temporary.name) / 'bundle'
        for name in ('game/main/base.iwd', 'game/zone/map.ff', 'game/steam_api.so', 'game/steamclient.so',
                     'mod/mod.ff', 'mod/mod.iwd', 'runtime/mods/opencj/checkpoints/draft.a', 'database.sql'):
            path = self.bundle / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'fixture bytes')

    def write_manifest(self, *, includes_assets):
        files = source.bundle_inventory(self.bundle, directories=('game', 'mod', 'runtime', 'source-config')
                                        if includes_assets else ('runtime', 'source-config'))
        save_json(self.bundle / 'manifest.json', {
            'format': source.FORMAT_VERSION, 'database': 'fixture_cod4', 'map': 'mp_killhouse',
            'mysql_version': '8.0.46', 'tables': {}, 'files': files, 'includes_assets': includes_assets})

    def test_copy_without_assets_validates_only_data(self):
        for kind in ('game', 'mod'):
            for path in sorted((self.bundle / kind).rglob('*'), reverse=True):
                path.unlink() if path.is_file() else path.rmdir()
            (self.bundle / kind).rmdir()
        self.write_manifest(includes_assets=False)
        self.assertEqual(migration.validate_bundle(self.bundle)['database'], 'fixture_cod4')

    def test_moved_assets_are_skipped_but_data_is_still_verified(self):
        self.write_manifest(includes_assets=True)
        for kind in ('game', 'mod'):
            (self.bundle / kind).rename(self.bundle.parent / kind)
        migration.validate_bundle(self.bundle, published_kinds=['game', 'mod'])
        (self.bundle / 'database.sql').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'checksum'):
            migration.validate_bundle(self.bundle, published_kinds=['game', 'mod'])


class FirewallTests(unittest.TestCase):
    def test_rules_cover_ssh_game_ports_and_https_only(self):
        installations = [
            {'port': 28960, 'bind_ip': '0.0.0.0', 'website': {'domain': 'opencj.org'}},
            {'port': 28961, 'bind_ip': '0.0.0.0'},
            {'port': 28962, 'bind_ip': '127.0.0.1'},
        ]
        with patch.object(firewall, 'ssh_ports', return_value=[22]):
            rules = firewall.wanted_rules({}, installations, extra_ssh_ports=[2222])
        self.assertIn((22, 'tcp', 'limit'), rules)
        self.assertIn((2222, 'tcp', 'limit'), rules)
        self.assertIn((28960, 'udp', 'allow'), rules)
        self.assertIn((443, 'tcp', 'allow'), rules)
        self.assertNotIn((28962, 'udp', 'allow'), rules, 'A loopback-only server must stay closed')
        self.assertFalse(any(port in (3306, 8090) for port, protocol, action in rules))


class CrashAlertTests(unittest.TestCase):
    settings = {'join_password': 'joinsecret123', 'rcon_password': 'rconsecret456',
                'database': {'password': 'dbsecret789'}}

    def metadata(self, restart_count):
        return {'Id': 'abc123', 'RestartCount': restart_count,
                'State': {'StartedAt': '2027-06-01T03:30:00Z', 'ExitCode': 139}}

    def test_crash_is_reported_once_with_masked_log(self):
        log = ('SV packet 203.0.113.7:28960: getstatus\n' + 'rcon from 198.51.100.2 with rconsecret456\n'
               + 'x' * 5000 + '\nSegmentation fault\n').encode()
        state = {}
        sent = []
        logs = type('Result', (), {'stdout': log, 'stderr': b''})()
        with patch.object(maintenance.subprocess, 'run', return_value=logs), \
                patch.object(maintenance, 'send_alert', lambda host, message: sent.append(message)):
            maintenance.report_crash_restart(Path('/srv/opencj'), state, 'main-eu', self.settings, self.metadata(0))
            self.assertEqual(sent, [], 'The first observation only records the counter')
            maintenance.report_crash_restart(Path('/srv/opencj'), state, 'main-eu', self.settings, self.metadata(1))
            maintenance.report_crash_restart(Path('/srv/opencj'), state, 'main-eu', self.settings, self.metadata(1))
        self.assertEqual(len(sent), 1, 'One crash must produce exactly one alert')
        message = sent[0]
        self.assertIn('exit code 139', message)
        self.assertIn('Segmentation fault', message)
        self.assertLessEqual(len(message), maintenance.DISCORD_MESSAGE_MAX_CHARACTERS)
        for secret in ('203.0.113.7', '198.51.100.2', 'rconsecret456'):
            self.assertNotIn(secret, maintenance.redact_log(log.decode(), self.settings))


class MapTests(unittest.TestCase):
    def test_map_folder_accepts_only_game_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary) / 'mp_secret'
            folder.mkdir()
            (folder / 'mp_secret.ff').write_bytes(b'ff')
            (folder / 'mp_secret_load.ff').write_bytes(b'ff')
            self.assertEqual(maps.find_map_folder(Path(temporary))[1], 'mp_secret')
            maps.validate_map(folder, 'mp_secret')
            (folder / 'readme.txt').write_text('no')
            with self.assertRaisesRegex(ValueError, 'Unexpected file'):
                maps.validate_map(folder, 'mp_secret')
        with self.assertRaisesRegex(ValueError, 'lowercase'):
            maps.validate_map(Path('.'), 'Mp-Bad')


if __name__ == '__main__':
    unittest.main()
