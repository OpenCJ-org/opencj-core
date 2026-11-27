"""Setup recovery: deferred settings, interrupted publication, damaged backups and shared writers."""

from contextlib import ExitStack
import gzip
from pathlib import Path
import tempfile
import shutil
import unittest
from unittest.mock import patch, MagicMock
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'setup'))
import database_maintenance
import install
import manage
import migration
import offsite
from operations import read_json, save_json
import service_control
import source


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.host = Path(temporary.name)
        game = self.host / 'assets/game'
        mod = self.host / 'assets/mod'
        for folder in ('main', 'zone/english', 'usermaps/mp_previous'):
            (game / folder).mkdir(parents=True)
        for name in ('main/base.iwd', 'steam_api.so', 'steamclient.so', 'usermaps/mp_previous/mp_previous.ff'):
            (game / name).touch()
        mod.mkdir(parents=True)
        (mod / 'mod.ff').touch()
        (mod / 'mod.iwd').touch()
        self.instance = self.host / 'main'
        self.instance.mkdir()
        self.settings = install.initialize_instance(self.instance, {
            'name': 'main', 'game_assets': str(game), 'mod_assets': str(mod),
            'database': {'mode': 'new'}, 'backups': {'enabled': False},
            'pruning': {'enabled': False}, 'geoip': {'enabled': False}})
        install.prepare_instance(self.instance, self.settings)
        self.settings['state'] = 'ready'
        install.save_installation(self.instance, self.settings)
        self.plan = {'host_dir': str(self.host), 'instances': [self.settings], 'completed': ['main']}
        save_json(self.host / 'host-setup.json', self.plan)

    def test_declining_configuration_preserves_live_files_and_stages_changes(self):
        original = (self.instance / 'server.cfg').read_bytes()
        changed = {**self.settings, 'hostname': 'Deferred name'}
        with patch.object(manage, 'collect_changes', return_value=changed), \
                patch.object(install, 'switched_off', return_value=False), \
                patch.object(install, 'held', return_value=False), \
                patch.object(service_control, 'active_game', return_value={'map': 'mp_previous', 'players': ['A', 'B']}), \
                patch.object(manage, 'ask_yes_no', return_value=False), \
                patch.object(manage, 'start_services') as start, patch('builtins.print') as printed:
            manage.configure_instance(self.host, 'main')
        start.assert_not_called()
        self.assertEqual((self.instance / 'server.cfg').read_bytes(), original)
        self.assertEqual(read_json(self.instance / 'installation.json')['hostname'], self.settings['hostname'])
        self.assertEqual(read_json(self.instance / 'pending-configuration.json')['settings']['hostname'], 'Deferred name')
        self.assertTrue(any('2 connected player(s)' in str(call) for call in printed.call_args_list))

    def test_unknown_player_count_does_not_offer_immediate_restart(self):
        with patch.object(manage, 'collect_changes', return_value={**self.settings, 'slots': 16}), \
                patch.object(install, 'switched_off', return_value=False), \
                patch.object(install, 'held', return_value=False), \
                patch.object(service_control, 'active_game', side_effect=RuntimeError('console unavailable')), \
                patch.object(manage, 'ask_yes_no') as question, patch('builtins.print'):
            manage.configure_instance(self.host, 'main')
        question.assert_not_called()
        self.assertTrue((self.instance / 'pending-configuration.json').exists())

    def test_recreation_replaces_game_and_optional_services_and_restores_map(self):
        settings = {**self.settings, 'discord': {'enabled': True}}
        with patch.object(install, 'compose') as compose, \
                patch.object(service_control, 'verify_running_files') as verify, \
                patch.object(service_control, 'restore_map') as restore:
            manage.start_services(self.instance, settings, recreate=True, active_map='mp_previous')
        game = next(call.args for call in compose.call_args_list if 'server' in call.args)
        bridge = next(call.args for call in compose.call_args_list if 'discord' in call.args)
        self.assertIn('--force-recreate', game)
        self.assertIn('--no-deps', game, 'Recreating gameplay must not recreate its database')
        self.assertIn('--force-recreate', bridge)
        verify.assert_called_once_with(self.instance, settings)
        restore.assert_called_once_with(self.instance, settings, 'mp_previous')

    def test_missing_previous_map_keeps_start_map(self):
        with patch.object(service_control.source, 'set_source_map') as change, patch('builtins.print'):
            service_control.restore_map(self.instance, self.settings, 'mp_removed')
        change.assert_not_called()

    def test_truncated_gzip_is_rejected_before_sql_can_run(self):
        backup = self.instance / 'truncated.sql.gz'
        backup.write_bytes(gzip.compress(b'SELECT 1;\n')[:-8])
        with self.assertRaisesRegex(RuntimeError, 'damaged'):
            with manage.validated_backup(self.instance, backup):
                self.fail('A damaged archive reached the SQL import phase')
        self.assertFalse(any(path.name.startswith('tmp') for path in self.instance.iterdir()))

    def test_validated_sql_is_complete_and_seekable(self):
        backup = self.instance / 'complete.sql.gz'
        sql = b'SELECT 42;\n' * 1000
        backup.write_bytes(gzip.compress(sql))
        with manage.validated_backup(self.instance, backup) as validated:
            self.assertEqual(validated.read(), sql)
            validated.seek(0)
            self.assertEqual(validated.read(10), sql[:10])

    def test_old_migration_prefix_is_accepted_but_modified_history_is_rejected(self):
        migrations = manage.migrate.load_migrations()
        rows = {version: [name, digest, 'applied'] for version, (name, digest, sql) in migrations.items()
                if version < max(migrations)}
        with patch.object(install, 'database_client'), patch.object(manage.migrate, 'read_ledger', return_value=rows):
            self.assertEqual(manage.applied_migrations(self.instance, self.settings, allow_pending=True), len(rows))
            rows[1][1] = '0' * 64
            with self.assertRaisesRegex(RuntimeError, 'differs'):
                manage.applied_migrations(self.instance, self.settings, allow_pending=True)

    def test_move_completed_before_receipt_is_reconciled_and_checked(self):
        bundle = self.instance / 'migration/bundle'
        (bundle / 'runtime').mkdir(parents=True)
        for kind in ('game', 'mod'):
            shutil.copytree(self.host / 'assets' / kind, bundle / kind)
        (bundle / 'database.sql').write_text('SELECT 1;')
        manifest = {'format': source.FORMAT_VERSION, 'database': 'fixture_cod4', 'map': 'mp_previous',
                    'files': source.bundle_inventory(bundle), 'tables': {}}
        save_json(bundle / 'manifest.json', manifest)
        settings = {**self.settings, 'migration': {'verified': True}}
        target_root = self.host / 'published'
        real_save = migration.save_json

        def fail_after_mod_move(path, record):
            if record['migration'].get('published_kinds') == ['game', 'mod']:
                raise OSError('power failure after rename')
            real_save(path, record)

        with patch.object(migration, 'shared_assets_root', return_value=target_root):
            with patch.object(migration, 'save_json', side_effect=fail_after_mod_move):
                with self.assertRaisesRegex(OSError, 'power failure'):
                    migration.publish_shared_assets(self.instance, settings, bundle, manifest)
            recovered = read_json(self.instance / 'installation.json')
            migration.reconcile_asset_publication(self.instance, recovered, bundle)
            migration.validate_bundle(bundle, published_kinds=recovered['migration']['published_kinds'])
            self.assertEqual(recovered['migration']['published_kinds'], ['game', 'mod'])
            self.assertTrue((target_root / 'mod/mod.ff').exists())

    def maintenance_fixture(self, *, running=True):
        peer = self.host / 'shared'
        peer.mkdir()
        shared = {**self.settings, 'name': 'shared', 'instance_dir': str(peer),
                  'database': {**self.settings['database'], 'mode': 'existing', 'owner_instance': str(self.instance)}}
        save_json(peer / 'installation.json', shared)
        events = []

        def compose(directory, settings, *arguments, **options):
            events.append((directory.name, arguments))
            if '--services' in arguments:
                if not running:
                    return ''
                return 'server\ndb' if directory == self.instance else 'server'
            return ''

        database = MagicMock()
        def query(sql):
            events.append(('sql', sql))
            return '0\t0' if sql.startswith('SELECT @@global') else ''
        database.query.side_effect = query
        stack = ExitStack()
        self.addCleanup(stack.close)
        stack.enter_context(patch.object(install, 'verify_managed_files'))
        stack.enter_context(patch.object(install, 'compose', side_effect=compose))
        client = stack.enter_context(patch.object(install, 'database_client'))
        client.return_value.__enter__.return_value = database
        stack.enter_context(patch.object(service_control, 'active_game', return_value={'map': 'mp_previous', 'players': []}))
        stack.enter_context(patch.object(install, 'check_ready'))
        stack.enter_context(patch.object(install, 'provision_game_account'))
        return peer, events

    def test_failure_keeps_all_shared_writers_stopped_and_retry_resumes_maps(self):
        peer, events = self.maintenance_fixture()
        with self.assertRaisesRegex(RuntimeError, 'import failed'):
            with database_maintenance.DatabaseMaintenance(self.instance, 'restore'):
                self.assertTrue((peer / service_control.MAINTENANCE_RECORD).exists())
                raise RuntimeError('import failed')
        self.assertTrue((self.instance / service_control.MAINTENANCE_RECORD).exists())
        stops = [name for name, command in events if isinstance(command, tuple) and command[0] == 'stop']
        self.assertEqual(stops, ['main', 'shared'])
        fence = next(index for index, event in enumerate(events) if event == ('sql', 'SET PERSIST read_only=ON;'))
        self.assertTrue(all(index < fence for index, event in enumerate(events)
                            if isinstance(event[1], tuple) and event[1][0] == 'stop'))
        starts = MagicMock()
        with database_maintenance.DatabaseMaintenance(self.instance, 'restore') as group:
            group.resume(starts)
        self.assertEqual(starts.call_count, 2)
        self.assertTrue(all(call.kwargs['active_map'] == 'mp_previous' for call in starts.call_args_list))
        self.assertFalse((self.instance / service_control.MAINTENANCE_RECORD).exists())
        self.assertFalse((peer / service_control.MAINTENANCE_RECORD).exists())

    def test_database_maintenance_keeps_previously_stopped_services_off(self):
        peer, events = self.maintenance_fixture(running=False)
        starts = MagicMock()
        with database_maintenance.DatabaseMaintenance(self.instance, 'restore') as group:
            group.resume(starts)
        starts.assert_not_called()
        self.assertIn(('main', ('stop', 'db')), events)

    def test_restore_activation_retry_does_not_import_over_accepted_data(self):
        peer, events = self.maintenance_fixture()
        backup = self.host / 'fixture.sql.gz'
        backup.write_bytes(gzip.compress(b'SELECT 1;\n'))
        with database_maintenance.DatabaseMaintenance(self.instance, 'restore') as group:
            group.journal.update(data_ready=True, safety='fixture safety backup',
                                 backup_sha256=migration.sha256_file(backup))
            save_json(group.record, group.journal)
        with patch.object(manage, 'start_services'), patch.object(manage, 'upgrade_database') as upgrade, \
                patch.object(manage, 'run') as sql_import:
            manage.restore_backup(self.host, 'main', backup, assume_yes=True)
        sql_import.assert_not_called()
        upgrade.assert_not_called()
        self.assertFalse(any('DROP DATABASE' in str(event) for event in events))

    def test_configuration_retry_accepts_owned_partial_write_but_preserves_operator_edits(self):
        before = dict(self.settings['managed_hashes'])
        pending = self.instance / 'pending-configuration.json'
        save_json(pending, {'applying': True, 'settings': self.settings, 'base_hashes': before})
        config = self.instance / 'server.cfg'
        replacement = config.read_text() + '// owned retry fixture\n'
        install.write_generated(config, replacement, replace=True)
        record = read_json(pending)
        service_control.verify_configuration_retry(self.instance, self.settings, record)
        install.write_generated(config, replacement, replace=True)
        config.write_text('// operator edit after interrupted apply\n')
        with self.assertRaisesRegex(RuntimeError, 'operator changes'):
            service_control.verify_configuration_retry(self.instance, self.settings, record)
        with self.assertRaisesRegex(RuntimeError, 'preserved'):
            install.write_generated(config, replacement, replace=True)
        self.assertEqual(config.read_text(), '// operator edit after interrupted apply\n')

    def test_upgrade_partial_configuration_accepts_only_journalled_writes(self):
        receipt = self.instance / service_control.UPGRADE_FILES_RECORD
        save_json(receipt, {'applying': True, 'base_hashes': self.settings['managed_hashes']})
        config = self.instance / 'server.cfg'
        install.write_generated(config, config.read_text() + '// upgraded fixture\n', replace=True)
        install.verify_managed_files(self.instance, self.settings)
        config.write_text('// unrelated manual edit\n')
        with self.assertRaisesRegex(RuntimeError, 'operator changes'):
            install.verify_managed_files(self.instance, self.settings)

    def test_refresh_retry_keeps_original_runtime_after_interrupted_rename(self):
        runtime = self.instance / 'runtime'
        runtime.mkdir(exist_ok=True)
        (runtime / 'draft').write_text('original draft')
        previous = self.instance / 'runtime.previous-fixture'
        bundle = self.instance / 'migration/refresh-fixture'
        manifest = {'files': {'runtime/draft': {'sha256': migration.sha256_file(runtime / 'draft')}}}
        (bundle / 'runtime').mkdir(parents=True)
        (bundle / 'runtime/draft').write_text('original draft')
        save_json(bundle / 'manifest.json', manifest)
        real_replace = manage.os.replace

        def interrupted_rename(source_path, target):
            real_replace(source_path, target)
            if target == previous:
                raise OSError('interrupted after runtime rename')

        with patch.object(manage.os, 'replace', side_effect=interrupted_rename):
            with self.assertRaisesRegex(OSError, 'interrupted'):
                manage.restore_refresh_runtime(self.instance, self.settings, bundle, previous)
        with patch.object(manage.os, 'chown'):
            manage.restore_refresh_runtime(self.instance, self.settings, bundle, previous)
            manage.restore_refresh_runtime(self.instance, self.settings, bundle, previous)
        self.assertEqual((previous / 'draft').read_text(), 'original draft')
        self.assertEqual((runtime / 'draft').read_text(), 'original draft')

    def test_unmounted_receiver_is_refused(self):
        receiver = self.host / 'receiver'
        receiver.mkdir()
        image, record = offsite.receiver_storage_paths(receiver)
        image.touch()
        save_json(record, {'directory': str(receiver), 'bytes': 0, 'uuid': 'fixture'})
        with self.assertRaisesRegex(RuntimeError, 'not mounted'):
            offsite.require_receiver_storage(receiver)

    def test_receiver_refuses_to_cover_existing_backups(self):
        receiver = self.host / 'receiver'
        receiver.mkdir()
        (receiver / 'existing.sql.gz').write_bytes(b'preserve')
        with self.assertRaisesRegex(RuntimeError, 'start empty'):
            offsite.prepare_receiver_storage(receiver, 1)
        self.assertEqual((receiver / 'existing.sql.gz').read_bytes(), b'preserve')


if __name__ == '__main__':
    unittest.main()
