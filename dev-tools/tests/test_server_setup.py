"""Portable release-installer checks: isolation, secret boundaries, archives and preservation."""

import io
import json
import os
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'setup'))
import assets
import configuration
import compose_config
import install


class ServerSetupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.game = self.root / 'game'
        (self.game / 'main').mkdir(parents=True)
        (self.game / 'zone').mkdir()
        for name in ('main/game.iwd', 'steam_api.so', 'steamclient.so'):
            (self.game / name).touch()
        self.mod = self.root / 'mod'
        self.mod.mkdir()
        (self.mod / 'mod.ff').touch()
        (self.mod / 'mod.iwd').touch()
        self.answers = {'name': 'main', 'game_assets': str(self.game), 'mod_assets': str(self.mod),
                        'database': {'mode': 'new'}, 'backups': {'enabled': False},
                        'geoip': {'enabled': False}, 'pruning': {'enabled': False}}
        self.instance = self.root / 'instance'
        self.instance.mkdir()

    def prepared(self):
        settings = install.initialize_instance(self.instance, self.answers)
        if settings['database'].get('transport') == 'ssh':
            settings['linux_accounts'] = {'tunnel': {'uid': os.getuid(), 'gid': os.getgid()}}
        install.prepare_instance(self.instance, settings)
        return settings

    def test_private_32_slot_defaults_and_unique_instance_storage(self):
        first = configuration.validate_configuration(self.answers)
        second = configuration.validate_configuration(self.answers)
        self.assertEqual(first['slots'], 32)
        self.assertFalse(first['public'])
        self.assertTrue(first['join_password'])
        self.assertNotEqual(first['volume'], second['volume'])
        self.assertNotEqual(first['database']['password'], second['database']['password'])

    def test_runtime_cannot_read_source_or_database_administrator_secret(self):
        settings = self.prepared()
        document = json.loads((self.instance / 'compose.json').read_text())
        server = document['services']['server']
        targets = [entry['target'] for entry in server['volumes']]
        self.assertNotIn('/workspace', targets)
        self.assertNotIn('/run/secrets/root-password', targets)
        self.assertTrue(server['read_only'])
        self.assertEqual(server['restart'], 'unless-stopped')
        self.assertEqual(document['volumes']['database']['name'], settings['volume'])
        self.assertTrue(document['volumes']['database']['external'])
        storage = document['services']['db']['volumes'][0]
        self.assertTrue(storage['volume']['nocopy'], 'Image copy-up must not replace owned data-directory permissions')
        self.assertIn('set g_password \"' + settings['join_password'] + '\"', (self.instance / 'server.cfg').read_text())
        self.assertNotIn(settings['root_password'], json.dumps(document))
        self.assertNotIn(settings['database']['password'], json.dumps(document))
        self.assertEqual((self.instance / 'installation.json').stat().st_mode & 0o777, 0o600)

    def test_existing_config_is_preserved(self):
        settings = self.prepared()
        original = (self.instance / 'server.cfg').read_bytes()
        with self.assertRaisesRegex(ValueError, 'not empty'):
            install.initialize_instance(self.instance, self.answers)
        self.assertEqual((self.instance / 'server.cfg').read_bytes(), original)
        (self.instance / 'server.cfg').write_text('operator changes\n')
        with self.assertRaisesRegex(RuntimeError, 'operator changes'):
            install.verify_managed_files(self.instance, settings)
        self.assertEqual((self.instance / 'server.cfg').read_text(), 'operator changes\n')

    def test_same_host_join_copies_only_the_runtime_account(self):
        settings = self.prepared()
        settings['state'] = 'ready'
        install.save_installation(self.instance, settings)
        shared = configuration.resolve_database({'mode': 'instance', 'instance_dir': str(self.instance)})
        self.assertEqual(shared['password'], settings['database']['password'])
        self.assertNotIn('root_password', shared)
        self.assertEqual(shared['network'], settings['project'] + '_default')

    def test_existing_database_never_bootstraps_or_changes_grants(self):
        settings = self.prepared()
        settings['database']['mode'] = 'existing'
        with patch.object(install, 'wait_for_database'), patch.object(install, 'database_client'), \
             patch.object(install, 'check_database', return_value=26), \
             patch.object(install, 'check_runtime_grants'), \
             patch.object(install.bootstrap, 'bootstrap') as bootstrap, \
             patch.object(install.runtime_access, 'apply_policy') as grants:
            install.initialize_database(self.instance, settings)
        bootstrap.assert_not_called()
        grants.assert_not_called()

    def test_shared_account_requires_complete_reviewed_policy(self):
        class PolicyDatabase:
            def __init__(self):
                self.grants = ["GRANT USAGE ON *.* TO 'opencj'@'%'"]

            def query(self, sql):
                if sql.startswith('GRANT '):
                    self.grants.append(sql.rstrip(';'))
                    return ''
                if 'ROUTINE_NAME' in sql:
                    return 'saveRun\tPROCEDURE'
                if sql == 'SELECT DATABASE();':
                    return 'fixture_cod4'
                if sql == 'SHOW GRANTS FOR CURRENT_USER;':
                    return '\n'.join(self.grants)
                raise AssertionError('Unexpected policy query')

        database = PolicyDatabase()
        install.runtime_access.grant_gameplay_permissions(database, 'fixture_cod4', "'opencj'@'%'")
        install.check_runtime_grants(database)
        valid_grants = list(database.grants)
        for additional in ("GRANT FILE ON *.* TO 'opencj'@'%'",
                           "GRANT SELECT ON *.* TO 'opencj'@'%'",
                           "GRANT 'administrator'@'%' TO 'opencj'@'%'",
                           "GRANT DELETE ON `fixture_cod4`.`playerSaves` TO 'opencj'@'%'",
                           "GRANT SELECT ON `fixture_cod4`.* TO 'opencj'@'%'",
                           valid_grants[-1] + ' WITH GRANT OPTION'):
            with self.subTest(grant=additional):
                database.grants = valid_grants + [additional]
                with self.assertRaisesRegex(RuntimeError, 'outside'):
                    install.check_runtime_grants(database)
        database.grants = valid_grants[:-1]
        with self.assertRaisesRegex(RuntimeError, 'missing required'):
            install.check_runtime_grants(database)

    def test_invalid_inputs_do_not_create_installation_files(self):
        for change in ({'name': '../escape'}, {'port': 70000}, {'slots': 65}, {'public': 'false'},
                       {'hostname': 'bad";exec other.cfg'}, {'map': 'map;quit'}):
            answers = {**self.answers, **change}
            with self.subTest(change=change):
                with self.assertRaises(ValueError):
                    install.initialize_instance(self.instance, answers)
                self.assertEqual(list(self.instance.iterdir()), [])

    def test_ready_repeat_run_does_not_build_or_start_any_service(self):
        settings = self.prepared()
        settings['state'] = 'ready'
        with patch.object(install, 'check_ready') as check, \
             patch.object(install, 'build_release') as build, patch.object(install, 'compose') as compose:
            install.install(self.instance, settings)
        check.assert_called_once_with(self.instance, settings)
        build.assert_not_called()
        compose.assert_not_called()

    def test_copied_installation_record_cannot_control_the_original_instance(self):
        self.prepared()
        other = self.root / 'other'
        other.mkdir()
        (other / 'installation.json').write_bytes((self.instance / 'installation.json').read_bytes())
        with self.assertRaisesRegex(ValueError, 'another directory'):
            install.load_installation(other)

    def test_partial_asset_preparation_can_resume_without_new_database_identity(self):
        incomplete = self.root / 'incomplete.zip'
        with zipfile.ZipFile(incomplete, 'w') as output:
            output.writestr('mod.ff', b'fixture')
        self.answers['mod_assets'] = str(incomplete)
        settings = install.initialize_instance(self.instance, self.answers)
        original_password = settings['database']['password']
        with self.assertRaisesRegex(ValueError, 'IWD'):
            install.prepare_instance(self.instance, settings)
        with zipfile.ZipFile(incomplete, 'w') as output:
            output.writestr('mod.ff', b'fixture')
            output.writestr('mod.iwd', b'fixture')
        recovered = install.load_installation(self.instance)
        install.prepare_instance(self.instance, recovered)
        self.assertEqual(recovered['database']['password'], original_password)
        self.assertEqual(recovered['state'], 'prepared')

    def test_partial_preparation_preserves_an_edited_generated_file(self):
        settings = self.prepared()
        (self.instance / 'server.cfg').write_text('operator edit')
        with self.assertRaisesRegex(RuntimeError, 'preserved'):
            install.write_instance_files(self.instance, settings)
        self.assertEqual((self.instance / 'server.cfg').read_text(), 'operator edit')

    def test_a_verified_download_checks_the_actual_payload(self):
        payload = b'archive fixture bytes'
        checksum = assets.hashlib.sha256(payload).hexdigest()
        response = io.BytesIO(payload)
        response.url = 'https://assets.example.invalid/archive'
        with patch.object(assets.urllib.request, 'urlopen', return_value=response):
            assets.download_archive(response.url, self.root / 'download', checksum)
        self.assertEqual((self.root / 'download').read_bytes(), payload)
        corrupt = io.BytesIO(b'changed')
        corrupt.url = response.url
        with patch.object(assets.urllib.request, 'urlopen', return_value=corrupt):
            with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                assets.download_archive(corrupt.url, self.root / 'corrupt', checksum)

    def test_archive_traversal_and_links_leave_destination_empty(self):
        for name, link in [('../escaped', False), ('/absolute', False), ('C:\\escape', False), ('link', True)]:
            with self.subTest(name=name):
                archive = self.root / 'bad.tar'
                with tarfile.open(archive, 'w') as output:
                    entry = tarfile.TarInfo(name)
                    if link:
                        entry.type = tarfile.SYMTYPE
                        entry.linkname = '/etc'
                    else:
                        entry.size = 1
                    output.addfile(entry, None if link else io.BytesIO(b'x'))
                destination = self.root / 'extracted'
                destination.mkdir(exist_ok=True)
                with self.assertRaises(ValueError):
                    assets.extract_archive(archive, destination)
                self.assertEqual(list(destination.iterdir()), [])
        self.assertFalse((self.root / 'escaped').exists())

    def test_uploaded_archive_is_validated_before_publication(self):
        archive = self.root / 'mod.zip'
        with zipfile.ZipFile(archive, 'w') as output:
            output.writestr('mod.ff', b'fixture-fastfile')
            output.writestr('mod.iwd', b'fixture-iwd')
        installed = assets.prepare_assets(str(archive), 'mod', self.instance)
        self.assertEqual((installed / 'mod.ff').read_bytes(), b'fixture-fastfile')
        self.assertEqual(list(assets.shared_assets_root(self.instance).glob('.mod-*')), [])

    def test_failed_asset_import_releases_temporary_files(self):
        archive = self.root / 'incomplete.zip'
        with zipfile.ZipFile(archive, 'w') as output:
            output.writestr('mod.ff', b'fixture')
        with self.assertRaisesRegex(ValueError, 'IWD'):
            assets.prepare_assets(str(archive), 'mod', self.instance)
        self.assertEqual(list(assets.shared_assets_root(self.instance).iterdir()), [])

    def test_download_requires_https_and_a_known_checksum_before_network_access(self):
        for url, checksum in [('http://example.invalid/assets', '0' * 64),
                              ('https://example.invalid/assets', ''),
                              ('https://user:password@example.invalid/assets', '0' * 64)]:
            with self.subTest(url=url), patch.object(assets.urllib.request, 'urlopen') as network:
                with self.assertRaises(ValueError):
                    assets.download_archive(url, self.root / 'download', checksum)
                network.assert_not_called()

    def test_custom_schema_baseline_does_not_select_or_create_the_historical_database(self):
        baseline = install.bootstrap.baseline_sql()
        self.assertNotIn('CREATE DATABASE', baseline)
        self.assertNotIn('USE `openCJ_cod4`', baseline)
        self.assertIn('FK_playerRuns_openCJ_cod4.checkpoints', baseline)

    def test_website_defaults_off_and_missing_project_is_rejected(self):
        settings = configuration.validate_configuration(self.answers)
        self.assertNotIn('website_compose', settings)
        self.answers['website_compose'] = str(self.root / 'missing.yaml')
        with self.assertRaisesRegex(ValueError, 'not supplied'):
            configuration.validate_configuration(self.answers)

    def test_server_browser_address_and_location_reach_the_game(self):
        self.answers['address'] = 'eu.example.org'
        self.answers['location'] = 'Netherlands'
        self.prepared()
        config = (self.instance / 'server.cfg').read_text()
        self.assertIn('set opencj_server_address "eu.example.org:28960"', config)
        self.assertIn('set opencj_server_location "Netherlands"', config)
        runtime = json.loads((self.instance / 'runtime.json').read_text())
        self.assertEqual(runtime['name'], 'main', 'the instance name becomes the server ID')

    def test_server_without_address_stays_out_of_the_browser(self):
        self.prepared()
        config = (self.instance / 'server.cfg').read_text()
        self.assertNotIn('opencj_server_address', config)
        self.assertNotIn('opencj_server_location', config)

    def test_unsafe_browser_location_is_rejected(self):
        self.answers['location'] = 'Somewhere"; quit'
        with self.assertRaisesRegex(ValueError, 'location'):
            configuration.validate_configuration(self.answers)

    def test_ssh_tunnel_requires_verified_host_keys_and_exposes_no_host_port(self):
        key = self.root / 'key'
        key.write_text('fixture-only-not-a-key')
        known = self.root / 'known_hosts'
        known.write_text('fixture-only-not-a-host-key')
        self.answers['database'] = {'mode': 'existing', 'transport': 'ssh', 'host': '127.0.0.1',
                                    'port': 3306, 'name': 'main_cod4', 'user': 'opencj',
                                    'password': 'synthetic-test-value',
                                    'ssh': {'host': 'db.example.invalid', 'port': 22, 'user': 'opencj',
                                            'key': str(key), 'known_hosts': str(known)}}
        settings = self.prepared()
        document = json.loads((self.instance / 'compose.json').read_text())
        tunnel = document['services']['db-tunnel']
        self.assertIn('StrictHostKeyChecking=yes', tunnel['command'])
        self.assertNotIn('ports', tunnel)
        self.assertIn('set db_host "db-tunnel"', (self.instance / 'server.cfg').read_text())
        self.assertNotIn('root_password', settings)


if __name__ == '__main__':
    unittest.main()
