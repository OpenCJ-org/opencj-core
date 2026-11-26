"""Operational setup features: retention, downloads, HTTPS routing, prompts, shared assets, firewall, maps."""

from datetime import datetime, timedelta, timezone
import gzip
import json
import os
from pathlib import Path
import socket
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'setup'))
import configuration
import dns_guide
import firewall
import install
import maintenance
import manage
import maps
import migration
import monitor
import source
import status
import website
from operations import save_json


def backup_name(moment):
    return moment.strftime('%Y%m%dT%H%M%SZ') + '.sql.gz'


class GameLogRotationTests(unittest.TestCase):
    """games_mp.log is copied away weekly, emptied in place and kept for 4 weeks only."""

    def make_log(self, instance, contents):
        folder = instance.joinpath(*maintenance.GAME_LOG_FOLDERS)
        folder.mkdir(parents=True)
        log = folder / maintenance.GAME_LOG_NAME
        log.write_bytes(contents)
        return log

    def test_log_is_archived_and_emptied(self):
        now = datetime(2026, 11, 29, 3, 30, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as directory:
            instance = Path(directory)
            log = self.make_log(instance, b'  0:00 InitGame\n  0:05 say;player;hello\n')
            maintenance.rotate_game_log(instance, now)
            archive = instance / maintenance.GAME_LOG_ARCHIVE_DIRECTORY / 'games_mp-20261129T033000Z.log.gz'
            self.assertEqual(gzip.decompress(archive.read_bytes()), b'  0:00 InitGame\n  0:05 say;player;hello\n')
            self.assertEqual(log.read_bytes(), b'', 'Emptied in place; the game keeps appending to it')
            maintenance.rotate_game_log(instance, now + timedelta(days=7))
            self.assertEqual(len(list(archive.parent.iterdir())), 1, 'An empty log makes no copy')

    def test_old_copies_are_deleted(self):
        with tempfile.TemporaryDirectory() as directory:
            instance = Path(directory)
            archives = instance / maintenance.GAME_LOG_ARCHIVE_DIRECTORY
            archives.mkdir()
            old, recent = archives / 'games_mp-20261001T033000Z.log.gz', archives / 'games_mp-20261115T033000Z.log.gz'
            for path, age_days in ((old, 29), (recent, 14)):
                path.write_bytes(b'')
                stamp = time.time() - age_days * 86400
                os.utime(path, (stamp, stamp))
            maintenance.rotate_game_log(instance, datetime.now(timezone.utc))
            self.assertEqual(sorted(archives.iterdir()), [recent])

    def test_links_planted_by_the_game_account_are_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            instance = Path(directory) / 'main-eu'
            target = Path(directory) / 'system-file'
            target.write_bytes(b'precious')
            log = self.make_log(instance, b'')
            log.unlink()
            log.symlink_to(target)
            with self.assertRaises(OSError):
                maintenance.rotate_game_log(instance, datetime.now(timezone.utc))
            log.unlink()
            os.link(target, log)
            with self.assertRaisesRegex(RuntimeError, 'not a plain file'):
                maintenance.rotate_game_log(instance, datetime.now(timezone.utc))
            self.assertEqual(target.read_bytes(), b'precious')

    def test_server_that_never_ran_has_no_log(self):
        with tempfile.TemporaryDirectory() as directory:
            maintenance.rotate_game_log(Path(directory), datetime.now(timezone.utc))


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
        return sorted(path.name for path in (self.directory / maintenance.RECEIVER_KEPT_DIRECTORY / sender).iterdir())

    def secure(self):
        with patch.object(maintenance.os, 'chown'):
            return maintenance.secure_received(self.directory, self.now)

    def test_tiered_retention_keeps_recent_daily_then_weekly_then_monthly(self):
        # One backup per day for 400 days.
        self.make_backups('main-eu', range(400))
        with patch.object(maintenance, 'datetime', wraps=datetime) as clock:
            clock.now.return_value = self.now
            with patch.object(maintenance.os, 'chown'):
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
            with patch.object(maintenance.os, 'chown'):
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
        self.assertEqual(self.secure(), [])
        self.assertEqual(len(self.remaining('main-eu')), 3)
        self.assertEqual([path.name for path in (self.directory / 'main-eu').iterdir()], ['notes.txt'])

    def test_a_hacked_sender_cannot_replace_or_push_out_backups(self):
        self.make_backups('main-eu', [1])
        self.secure()
        original = self.directory / '.kept' / 'main-eu' / backup_name(self.now - timedelta(days=1))
        self.assertEqual(original.read_bytes(), b'x' * 10)
        # Overwrite attempt with the same name, and fake "newest" backups dated in the future.
        (self.directory / 'main-eu' / original.name).write_bytes(b'garbage')
        for days in range(2, 10):
            (self.directory / 'main-eu' / backup_name(self.now + timedelta(days=days))).write_bytes(b'fake')
        warnings = self.secure()
        self.assertEqual(original.read_bytes(), b'x' * 10, 'A received backup must never change')
        self.assertEqual(self.remaining('main-eu'), [original.name])
        self.assertEqual(list((self.directory / 'main-eu').iterdir()), [])
        self.assertEqual(len(warnings), 9)
        self.assertIn('dated in the future', warnings[-1])
        alerts = []
        with patch.object(maintenance, 'send_alert', lambda host, message: alerts.append(message)), \
                patch.object(maintenance.os, 'chown'):
            (self.directory / 'main-eu' / backup_name(self.now + timedelta(days=30))).write_bytes(b'fake')
            maintenance.run_receiver_retention(self.directory, 50)
        self.assertEqual(len(alerts), 1, 'Unexpected uploads are reported')


class FailedJobAlertTests(unittest.TestCase):
    def test_a_job_that_keeps_failing_is_reported_once_per_six_hours(self):
        sent = []
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(maintenance, 'send_alert', lambda host, message: sent.append(message)), \
                patch('builtins.print'):
            for minute in range(0, 60, 2):
                with patch.object(maintenance.time, 'time', return_value=1_000_000 + minute * 60):
                    maintenance.alert_for_failed_unit(Path(directory), 'opencj-watchdog.service')
            with patch.object(maintenance.time, 'time', return_value=1_000_000 + maintenance.ALERT_REPEAT_SECONDS):
                maintenance.alert_for_failed_unit(Path(directory), 'opencj-watchdog.service')
                maintenance.alert_for_failed_unit(Path(directory), 'opencj-housekeeping.service')
        self.assertEqual(len(sent), 3)
        self.assertIn('opencj-housekeeping.service', sent[-1])


class OffsiteUploadTests(unittest.TestCase):
    def test_only_backups_the_receiver_lacks_are_sent(self):
        offsite = {'host': 'backup.example.net', 'port': 22, 'user': 'ocjoff_main_eu', 'known_hosts': 'x ssh-ed25519 A'}
        with tempfile.TemporaryDirectory() as directory:
            instance = Path(directory)
            (instance / 'secrets').mkdir()
            (instance / 'automatic-backups').mkdir()
            for day in (1, 2):
                (instance / 'automatic-backups' / f'2027060{day}T033000Z.sql.gz').write_bytes(b'x')
            commands = []
            with patch.object(maintenance, 'run', lambda command, **options: commands.append(command)), \
                    patch('builtins.print'):
                maintenance.upload_offsite(instance, offsite)
                (instance / 'automatic-backups' / '20270603T033000Z.sql.gz').write_bytes(b'x')
                maintenance.upload_offsite(instance, offsite)
                maintenance.upload_offsite(instance, offsite)
                maintenance.upload_offsite(instance, {**offsite, 'host': 'new-backup.example.net'})
        sent = [[Path(part).name for part in command if part.endswith('.sql.gz')] for command in commands]
        self.assertEqual(sent, [['20270601T033000Z.sql.gz', '20270602T033000Z.sql.gz'], ['20270603T033000Z.sql.gz'],
                                ['20270601T033000Z.sql.gz', '20270602T033000Z.sql.gz', '20270603T033000Z.sql.gz']])


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
        self.assertIn('redir https://opencj.org{uri} permanent', http_site)

    def test_extra_domains_redirect_to_the_main_domain(self):
        text = website.caddyfile({'domain': 'opencj.org', 'aliases': ['opencj.net', 'www.opencj.org'],
                                  'acme_email': ''})
        self.assertIn('opencj.net, www.opencj.org {\n\tredir https://opencj.org{uri} permanent', text)
        self.assertIn('http://opencj.org, http://opencj.net, http://www.opencj.org {', text,
                      'Map downloads must work over plain HTTP on every domain')
        self.assertEqual(text.count('reverse_proxy httpd:8080'), 2, 'Only the main site and /usermaps/ serve pages')

    def test_website_domain_and_invite_validation(self):
        for domain in ('http://opencj.org', 'OpenCJ.org', 'opencj'):
            with self.subTest(domain=domain), self.assertRaises(ValueError):
                website.validate_domain(domain)
        self.assertEqual(website.validate_invite('disabled'), '')
        with self.assertRaises(ValueError):
            website.validate_invite('https://example.com/invite')

    def test_extra_domains_are_validated(self):
        base = {'connect_address': 'opencj.org:28960', 'domain': 'opencj.org'}
        database = {'mode': 'new'}
        self.assertEqual(website.validate_website({**base, 'aliases': ['opencj.net']}, database)['aliases'],
                         ['opencj.net'])
        for aliases in (['opencj.org'], ['opencj.net', 'opencj.net'], ['http://opencj.net']):
            with self.subTest(aliases=aliases), self.assertRaises(ValueError):
                website.validate_website({**base, 'aliases': aliases}, database)
        with self.assertRaises(ValueError):
            website.validate_website({**base, 'domain': '', 'aliases': ['opencj.net']}, database)


class DnsGuideTests(unittest.TestCase):
    plan = {'instances': [
        {'name': 'main-eu', 'address': 'eu.opencj.org',
         'website': {'domain': 'opencj.org', 'aliases': ['opencj.net']}},
        {'name': 'map-test', 'address': ''},
    ]}
    here = {'A': ['203.0.113.10'], 'AAAA': ['2001:db8::10']}  # problems() compares text only

    def test_names_cover_website_domains_and_server_addresses(self):
        names = [name for name, purpose in dns_guide.wanted_names(self.plan)]
        self.assertEqual(names, ['opencj.org', 'opencj.net', 'eu.opencj.org'])

    def test_records_pointing_elsewhere_are_reported(self):
        cases = [
            ({'A': {'203.0.113.10'}, 'AAAA': set()}, []),
            ({'A': {'203.0.113.10'}, 'AAAA': {'2001:db8::10'}}, []),
            ({'A': set(), 'AAAA': set()}, ['has no A record']),
            ({'A': {'198.51.100.1'}, 'AAAA': set()}, ['A record points to 198.51.100.1, not here']),
        ]
        for resolved, expected in cases:
            with self.subTest(resolved=resolved), patch.object(dns_guide, 'resolve', return_value=resolved):
                self.assertEqual(dns_guide.problems('opencj.org', self.here), expected)
        with patch.object(dns_guide, 'resolve', return_value={'A': {'203.0.113.10'}, 'AAAA': {'2001:db8::99'}}):
            self.assertIn('AAAA', dns_guide.problems('opencj.org', self.here)[0],
                          'A wrong IPv6 record breaks certificates even when IPv4 is right')

    def test_public_addresses_skip_private_temporary_and_container_addresses(self):
        # Documentation ranges (203.0.113.0/24, 2001:db8::/32) are not "global" to Python,
        # so these tests use ordinary public-looking addresses.
        interfaces = [
            {'ifname': 'eth0', 'addr_info': [
                {'local': '45.10.20.30'}, {'local': '2a01:4f8::10'},
                {'local': '2a01:4f8::abcd', 'temporary': True}, {'local': '10.0.0.5'}]},
            {'ifname': 'docker0', 'addr_info': [{'local': '45.10.20.99'}]},
            # A real `ip -j address show scope global` lists other interfaces with empty entries.
            {'ifname': 'lo', 'addr_info': [{}]},
        ]
        with patch.object(dns_guide, 'run', return_value=json.dumps(interfaces)):
            found = dns_guide.public_addresses()
        self.assertEqual(found, {'A': ['45.10.20.30'], 'AAAA': ['2a01:4f8::10']},
                         'Private, Docker bridge and temporary IPv6 addresses are never published in DNS')

    def test_machine_behind_nat_uses_the_address_the_operator_gave(self):
        with patch.object(dns_guide, 'run', return_value=json.dumps([
                {'ifname': 'eth0', 'addr_info': [{'local': '192.168.1.20'}]}])):
            self.assertEqual(dns_guide.public_addresses({'public_ipv4': '45.10.20.30'})['A'], ['45.10.20.30'])
        with self.assertRaises(ValueError):
            dns_guide.validate_public_ipv4('192.168.1.20')


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
    # Made-up passwords: the test checks that crash logs never show them.
    settings = {'join_password': 'joinsecret123', 'rcon_password': 'rconsecret456',  # gitleaks:allow
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


class OutsideCheckTests(unittest.TestCase):
    """Another machine reports a game host that stopped answering, without noise from short restarts."""
    config = {'webhook': '', 'machines': {'main-eu': [
        {'kind': 'game', 'host': 'eu.opencj.org', 'port': 28960}, {'kind': 'web', 'url': 'https://opencj.org/'}]}}

    def run_rounds(self, outcomes, state=None, start=1_000_000):
        """outcomes: per round, the error for every target (None = answered); returns all posted lines."""
        state = {} if state is None else state
        posted = []
        for round_number, errors in enumerate(outcomes):
            replies = iter(errors)
            now = start + round_number * 120
            posted.append(monitor.run_checks(self.config, state, now, probe=lambda target: next(replies)))
        return posted

    def test_short_outage_is_not_reported(self):
        # A restart after an update or crash takes well under 6 minutes.
        posted = self.run_rounds([['timeout', None], ['timeout', None], [None, None]])
        self.assertEqual(posted, [[], [], []])

    def test_outage_is_reported_once_then_recovery(self):
        down = ['no answer', 'connection refused']
        posted = self.run_rounds([down, down, down, down, [None, None]])
        self.assertEqual([len(lines) for lines in posted], [0, 0, 2, 0, 2])
        self.assertIn('DOWN main-eu: game server eu.opencj.org:28960 - no answer', posted[2][0])
        self.assertIn('failing for about 4 min', posted[2][0])
        self.assertIn('RECOVERED main-eu: website https://opencj.org/', posted[4][1])

    def test_long_outage_is_repeated_every_six_hours(self):
        state = {}
        self.run_rounds([['x', None]] * 3, state)
        one_hour_later = self.run_rounds([['x', None]], state, start=1_000_000 + 3600)
        self.assertEqual(one_hour_later, [[]], 'An ongoing outage is not repeated every check')
        six_hours_later = self.run_rounds([['x', None]], state,
                                          start=1_000_000 + 240 + monitor.STILL_DOWN_REPEAT_SECONDS)
        self.assertEqual(len(six_hours_later[0]), 1)
        self.assertIn('failing for about 364 min', six_hours_later[0][0])

    def test_targets_are_validated(self):
        self.assertEqual(monitor.parse_target('game:eu.opencj.org:28960'),
                         {'kind': 'game', 'host': 'eu.opencj.org', 'port': 28960})
        self.assertEqual(monitor.parse_target('web:https://opencj.org/'), {'kind': 'web', 'url': 'https://opencj.org/'})
        for text in ('game:eu.opencj.org', 'game:host:99999', 'web:http://opencj.org/', 'ftp:x', 'game:a b:1'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                monitor.parse_target(text)

    def test_game_probe_needs_a_real_info_reply(self):
        # A local UDP server that answers like a CoD4 server, then one that stays silent.
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as server:
            server.bind(('127.0.0.1', 0))
            port = server.getsockname()[1]

            def answer():
                payload, client = server.recvfrom(4096)
                if payload == monitor.GAME_QUERY:
                    server.sendto(monitor.GAME_REPLY_PREFIX + b'\n\\hostname\\OpenCJ', client)
            responder = threading.Thread(target=answer)
            responder.start()
            self.assertIsNone(monitor.probe_game({'kind': 'game', 'host': '127.0.0.1', 'port': port}))
            responder.join(timeout=5)
            with patch.object(monitor, 'GAME_QUERY_TIMEOUT_SECONDS', 0.2):
                self.assertIn('no answer', monitor.probe_game({'kind': 'game', 'host': '127.0.0.1', 'port': port}))

    def test_game_host_prints_targets_for_public_servers_and_the_website(self):
        plan = {'public_ipv4': '45.10.20.30', 'instances': [
            {'name': 'main-eu', 'port': 28960, 'address': 'eu.opencj.org', 'website': {'domain': 'opencj.org'}},
            {'name': 'acceptance', 'port': 28961, 'address': ''},
            {'name': 'map-test', 'port': 28962, 'bind_ip': '127.0.0.1'}]}
        with patch.object(dns_guide, 'run', return_value='[]'):
            targets = manage.outside_check_targets(plan)
        self.assertEqual(targets, ['game:eu.opencj.org:28960', 'web:https://opencj.org/', 'game:45.10.20.30:28961'])
        for target in targets:
            monitor.parse_target(target)


class StatusTests(unittest.TestCase):
    """`opencj status` must flag every broken part, and stay quiet about normal states."""
    now = 1_800_000_000

    def test_services_missing_stopped_or_unhealthy_are_problems(self):
        rows = [{'Service': 'server', 'State': 'running', 'Health': 'healthy'},
                {'Service': 'db', 'State': 'running', 'Health': 'starting'},
                {'Service': 'discord', 'State': 'restarting', 'Health': ''}]
        text, problems = status.service_summary(['server', 'db', 'discord', 'geoip'], rows)
        self.assertEqual(text, 'server healthy · db starting · discord restarting · geoip missing')
        self.assertEqual(problems, ['discord is restarting', 'geoip is missing'],
                         'A database that is still starting is not a problem yet')
        _, problems = status.service_summary(['https'], [{'Service': 'https', 'State': 'running', 'Health': ''}])
        self.assertEqual(problems, [], 'A service without a healthcheck counts as fine while running')

    def test_jobs_report_failures_stale_runs_and_inactive_timers(self):
        recent = {'ActiveState': 'active', 'LastTriggerUSec': '@' + str(self.now - 60)}
        old = {'ActiveState': 'active', 'LastTriggerUSec': '@' + str(self.now - 3600)}
        cases = [
            ('watchdog', recent, {'Result': 'success'}, None),
            ('watchdog', old, {'Result': 'success'}, 'it has not run for 60 min'),
            ('main-eu backup', old, {'Result': 'exit-code'}, 'its last run failed'),
            ('main-eu backup', {'ActiveState': 'inactive'}, {}, 'its timer is not active'),
            ('housekeeping', {'ActiveState': 'active', 'LastTriggerUSec': ''}, {}, None),
        ]
        for label, timer, service, expected in cases:
            with self.subTest(label=label, timer=timer, service=service):
                self.assertEqual(status.job_summary(label, timer, service, self.now)[1], expected)
        self.assertEqual(status.job_summary('housekeeping', cases[4][1], {}, self.now)[0], 'not run yet')

    def test_timer_times_come_from_raw_dbus_values(self):
        self.assertEqual(status.unit_object_path('opencj-main-eu.timer'),
                         '/org/freedesktop/systemd1/unit/opencj_2dmain_2deu_2etimer')
        replies = {'LastTriggerUSec': 't 1795582850930867', 'ActiveState': 's "active"'}
        with patch.object(status, 'quiet', lambda arguments: replies[arguments[-1]]):
            self.assertEqual(status.timer_properties('opencj-watchdog'),
                             {'ActiveState': 'active', 'LastTriggerUSec': '@1795582850'})
        replies['LastTriggerUSec'] = 't 0'
        with patch.object(status, 'quiet', lambda arguments: replies[arguments[-1]]):
            self.assertEqual(status.timer_properties('opencj-watchdog')['LastTriggerUSec'], '', 'Never ran')

    def test_job_names_are_readable(self):
        projects = {'opencj-main-eu-66f61181': 'main-eu'}
        self.assertEqual(status.job_label('opencj-main-eu-66f61181-backup', projects), 'main-eu backup')
        self.assertEqual(status.job_label('opencj-main-eu-66f61181-prune', projects), 'main-eu pruning')
        self.assertEqual(status.job_label('opencj-watchdog', projects), 'watchdog')

    def test_certificate_close_to_expiry_is_a_problem(self):
        def certificate(days):
            return {'notAfter': time.strftime('%b %d %H:%M:%S %Y GMT', time.gmtime(self.now + days * 86400))}
        self.assertIsNone(status.certificate_summary(certificate(60), self.now)[1])
        text, problem = status.certificate_summary(certificate(5), self.now)
        self.assertIn('5 days left', text)
        self.assertEqual(problem, 'renewal seems to fail')

    def test_report_collects_only_problems(self):
        report = status.Report()
        self.assertEqual(report.check(True, 'fine'), 'OK')
        self.assertEqual(report.check(False, 'disk almost full'), 'PROBLEM')
        self.assertEqual(report.attention, ['disk almost full'])


class OnDemandTests(unittest.TestCase):
    """Test servers are off until started; being off is normal, not an outage."""
    plan = {'instances': [
        {'name': 'main-eu', 'port': 28960, 'website': {'domain': 'opencj.org'}},
        {'name': 'acceptance', 'port': 28961, 'copy_from': 'main-eu', 'on_demand': True},
        {'name': 'map-test', 'port': 28962, 'on_demand': True}]}

    def test_only_main_servers_run_always_by_default(self):
        with patch('builtins.input', lambda label: ''), patch('builtins.print'):
            self.assertFalse(configuration.ask_on_demand('main-eu'))
            self.assertTrue(configuration.ask_on_demand('map-test'))
            self.assertFalse(configuration.ask_on_demand('map-test', current=False), 'The current value wins')

    def test_servers_others_need_cannot_be_on_demand(self):
        configuration.check_on_demand(self.plan['instances'])
        for change, reason in (({'name': 'main-eu', 'website': {}}, 'acceptance copies its data'),
                               ({'name': 'main-eu', 'website': {'domain': 'opencj.org'}}, 'runs the website'),
                               ({'name': 'map-test', 'share_with': 'acceptance'}, 'map-test shares its database')):
            instances = [dict(item) for item in self.plan['instances']]
            for item in instances:
                if item['name'] == change['name']:
                    item.update(change)
            instances[0]['on_demand'] = True
            if change['name'] == 'map-test':
                instances[0]['on_demand'] = False
            with self.subTest(change=change), self.assertRaisesRegex(ValueError, reason):
                configuration.check_on_demand(instances)
        with self.assertRaisesRegex(ValueError, 'Boolean'):
            configuration.check_on_demand([{'name': 'map-test', 'on_demand': 'yes'}])

    def test_configure_offers_on_demand_only_where_allowed(self):
        with patch('builtins.print'):
            self.assertFalse(manage.on_demand_allowed(self.plan, dict(self.plan['instances'][0])))
            self.assertTrue(manage.on_demand_allowed(self.plan, dict(self.plan['instances'][2])))

    def test_switched_off_means_stopped_on_purpose(self):
        self.assertTrue(status.is_switched_off({'on_demand': True}, 'exited'))
        self.assertFalse(status.is_switched_off({'on_demand': True}, 'restarting'), 'A crash loop is a problem')
        self.assertFalse(status.is_switched_off({'on_demand': False}, 'exited'), 'An always-on server is down')
        settings = {'on_demand': True}
        with patch.object(install, 'compose', return_value=''):
            self.assertTrue(install.switched_off(Path('/srv/opencj/map-test'), settings))
        with patch.object(install, 'compose', return_value='abc123'):
            self.assertFalse(install.switched_off(Path('/srv/opencj/map-test'), settings))
        self.assertFalse(install.switched_off(Path('/srv/opencj/main-eu'), {}), 'Always-on servers are never off')

    def test_watchdog_ignores_only_servers_switched_off(self):
        stopped = {'State': {'Running': False, 'Restarting': False}}
        sent = []
        with tempfile.TemporaryDirectory() as directory:
            host = Path(directory)
            installations = [('map-test', host / 'map-test', {'on_demand': True}),
                             ('main-eu', host / 'main-eu', {'on_demand': False})]
            with patch.object(maintenance, 'ready_installations', return_value=installations), \
                    patch.object(install, 'compose', return_value='abc123'), \
                    patch('operations.inspect_container', return_value=stopped), \
                    patch.object(maintenance, 'report_crash_restart'), \
                    patch.object(maintenance, 'check_optional_services'), \
                    patch.object(maintenance, 'run', return_value=''), \
                    patch.object(maintenance, 'send_alert', lambda host, message: sent.append(message)):
                maintenance.run_watchdog(host)
        self.assertEqual(sent, ['main-eu: the game server is stopped.'])

    def test_outside_check_leaves_out_on_demand_servers(self):
        plan = {'public_ipv4': '45.10.20.30', 'instances': self.plan['instances']}
        with patch.object(dns_guide, 'run', return_value='[]'):
            targets = manage.outside_check_targets(plan)
        self.assertEqual(targets, ['game:45.10.20.30:28960', 'web:https://opencj.org/'])

    def test_maintenance_starts_a_switched_off_server_and_stops_it_again(self):
        calls = []
        settings = {'name': 'acceptance', 'on_demand': True}
        with patch.object(install, 'switched_off', return_value=True), \
                patch.object(manage, 'start_services', lambda instance, settings: calls.append('start')), \
                patch.object(install, 'stop_services', lambda instance, settings: calls.append('stop')), \
                patch('builtins.print'):
            with manage.running_for_maintenance(Path('/srv/opencj/acceptance'), settings):
                calls.append('work')
            self.assertEqual(calls, ['start', 'work', 'stop'])
            calls.clear()
            with self.assertRaises(RuntimeError):
                with manage.running_for_maintenance(Path('/srv/opencj/acceptance'), settings):
                    raise RuntimeError('upgrade failed')
            self.assertEqual(calls, ['start'], 'After a failure the server stays on for inspection')

    def test_manual_stop_of_an_always_on_server_keeps_its_database(self):
        settings = {'name': 'main-eu', 'discord': {'enabled': True}}
        calls = []
        with tempfile.TemporaryDirectory() as directory:
            instance = Path(directory) / 'main-eu'
            instance.mkdir()
            with patch.object(install, 'load_installation', return_value=settings), \
                    patch.object(install, 'switched_off', return_value=False), \
                    patch.object(install, 'held', return_value=False), \
                    patch.object(install, 'current_boot', return_value='boot-1'), \
                    patch.object(manage, 'connected_players', return_value=0), \
                    patch.object(install, 'compose', lambda instance, settings, *arguments, **options:
                                 calls.append(arguments)), patch('builtins.print'):
                manage.stop_instance(Path(directory), 'main-eu', assume_yes=True)
            record = json.loads((instance / install.HOLD_RECORD).read_text())
        self.assertEqual(record['boot_id'], 'boot-1')
        self.assertEqual(calls, [('stop', '--timeout', str(install.STOP_GRACE_SECONDS), 'server', 'discord')],
                         'Only gameplay and chat stop; the database keeps running')

    def test_manual_stop_lasts_until_the_next_reboot(self):
        stopped = {'Running': False, 'Restarting': False}
        started = []
        with tempfile.TemporaryDirectory() as directory:
            instance = Path(directory)
            save_json(instance / install.HOLD_RECORD, {'boot_id': 'boot-1'})
            with patch.object(install, 'current_boot', return_value='boot-1'), \
                    patch.object(install, 'compose', lambda *arguments, **options: started.append(arguments)), \
                    patch('builtins.print'):
                self.assertTrue(maintenance.handle_manual_stop(instance, {'name': 'main-eu'}, stopped))
                self.assertEqual(started, [], 'Same boot: left alone, no alert')
            with patch.object(install, 'current_boot', return_value='boot-2'), \
                    patch.object(install, 'compose', lambda *arguments, **options: started.append(arguments)), \
                    patch('builtins.print'):
                self.assertTrue(maintenance.handle_manual_stop(instance, {'name': 'main-eu'}, stopped))
                self.assertEqual(started[0][2], 'start', 'After a reboot it is started again')
                self.assertFalse((instance / install.HOLD_RECORD).exists())
                self.assertFalse(maintenance.handle_manual_stop(instance, {'name': 'main-eu'}, stopped),
                                 'Without a record a stopped server is a problem again')
            save_json(instance / install.HOLD_RECORD, {'boot_id': 'boot-2'})
            with patch.object(install, 'current_boot', return_value='boot-2'):
                self.assertFalse(maintenance.handle_manual_stop(instance, {'name': 'main-eu'},
                                                                {'Running': True}))
            self.assertFalse((instance / install.HOLD_RECORD).exists(), 'Started by other means: stop forgotten')


class DiscordBridgeSetupTests(unittest.TestCase):
    """Setup side of the bridge: shared socket folder only, socket path in the environment, mention list."""

    def test_only_the_socket_folder_is_shared(self):
        document = {'services': {'server': {'tmpfs': ['/tmp:rw'], 'volumes': [], 'group_add': []}}}
        settings = {'linux_accounts': {'discord': {'uid': 10001, 'gid': 10002}}, 'discord_image': 'bridge:x'}
        from compose_config import add_discord_bridge, DISCORD_SOCKET_ENVIRONMENT
        add_discord_bridge(document, settings, Path('/srv/opencj/main-eu'))
        server, bridge = document['services']['server'], document['services']['discord']
        self.assertEqual(server['tmpfs'], ['/tmp:rw'], 'The game keeps its own /tmp')
        for service in (server, bridge):
            self.assertEqual(service['environment']['OPENCJ_DISCORD_SOCKET'], '/run/opencj-discord/events.sock')
            mount = service['volumes'][-1]
            self.assertEqual((mount['source'], mount['target'], mount['read_only']),
                             ('/srv/opencj/main-eu/sockets', '/run/opencj-discord', False))
        self.assertEqual(server['group_add'], ['10002'])
        self.assertEqual(DISCORD_SOCKET_ENVIRONMENT, {'OPENCJ_DISCORD_SOCKET': '/run/opencj-discord/events.sock'})

    def test_mention_list_is_validated(self):
        ids = ['1' * 18, '2' * 18]
        self.assertEqual(configuration.parse_mention_user_ids(' 111111111111111111, 222222222222222222,'
                                                              '111111111111111111 '), ids)
        self.assertEqual(configuration.parse_mention_user_ids(''), [])
        for text in ('everyone', '123', ','.join(str(10 ** 17 + n) for n in range(26))):
            with self.subTest(text=text[:20]), self.assertRaises(ValueError):
                configuration.parse_mention_user_ids(text)
        bridge = {'enabled': True, 'guild_id': '3' * 18, 'channel_id': '4' * 18, 'token': 'x' * 70}
        self.assertEqual(configuration.validate_discord(bridge)['mention_user_ids'], [],
                         'Existing installations without the list keep working')

    def test_config_file_lists_allowed_mentions(self):
        written = {}
        discord = {'enabled': True, 'guild_id': '3' * 18, 'channel_id': '4' * 18, 'token': 'tok',
                   'mention_user_ids': ['1' * 18, '2' * 18]}
        settings = {'discord': discord, 'linux_accounts': {'discord': {'uid': 10001, 'gid': 10002}}}
        with tempfile.TemporaryDirectory() as directory, patch.object(install.os, 'chown'), \
                patch.object(install, 'write_generated',
                             lambda path, text, **options: written.update({path.name: text})):
            (Path(directory) / 'secrets').mkdir()
            install.write_discord_files(Path(directory), settings, replace=True)
        self.assertEqual(written['config_cod4'], 'guildid=' + '3' * 18 + '\nchannelid=' + '4' * 18 + '\ntoken=tok\n'
                         'mentionuserids=' + '1' * 18 + ',' + '2' * 18 + '\n')

    def test_failed_upgrade_rolls_the_bridge_back_with_the_game(self):
        settings = {'name': 'main-eu', 'release': 'beta-0.2.0', 'image': 'new', 'image_id': 'sha-new',
                    'discord_image': 'p-discord:beta-0.2.0', 'geoip_image': 'p-geoip:beta-0.2.0',
                    'upgrade': {'from': 'beta-0.1.0', 'previous_image': 'old', 'previous_image_id': 'sha-old',
                                'migrations_before': [1], 'migrations_after': [1],
                                'previous_optional_images': {'discord_image': 'p-discord:beta-0.1.0',
                                                             'geoip_image': 'p-geoip:beta-0.1.0'}}}
        upgrade = settings['upgrade']
        with patch.object(install, 'write_instance_files'), patch.object(manage, 'start_services'), \
                patch.object(install, 'save_installation'), self.assertRaisesRegex(RuntimeError, 'previous release'):
            manage.roll_back(Path('/srv/opencj/main-eu'), settings, upgrade)
        self.assertEqual((settings['image'], settings['discord_image'], settings['geoip_image']),
                         ('old', 'p-discord:beta-0.1.0', 'p-geoip:beta-0.1.0'))


class DiscordChannelTests(unittest.TestCase):
    def test_two_bridges_cannot_share_a_channel(self):
        bridge = {'enabled': True, 'guild_id': '1' * 18, 'channel_id': '2' * 18, 'token': 'x'}
        configuration.check_discord_channels([{'name': 'main-eu', 'discord': bridge},
                                              {'name': 'acceptance', 'discord': {'enabled': False}}])
        with self.assertRaisesRegex(ValueError, 'main-eu and acceptance would share'):
            configuration.check_discord_channels([{'name': 'main-eu', 'discord': bridge},
                                                  {'name': 'acceptance', 'discord': dict(bridge)}])


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
