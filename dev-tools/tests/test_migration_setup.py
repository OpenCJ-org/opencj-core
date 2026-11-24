"""Migration boundaries: corrupted transfers, retry preservation, topology and website grants."""

import gzip
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'dev-tools/setup'))
import host_plan
import migration
import maintenance
import source
import website
from operations import save_json


class MigrationSetupTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.bundle = self.root / 'bundle'
        for name in ('game/main', 'game/zone', 'game/usermaps', 'mod', 'runtime'):
            (self.bundle / name).mkdir(parents=True, exist_ok=True)
        for name in ('game/main/base.iwd', 'game/zone/map.ff', 'game/steam_api.so',
                     'game/steamclient.so', 'mod/mod.ff', 'mod/mod.iwd',
                     'runtime/mods/opencj/checkpoints/draft.a', 'database.sql'):
            path = self.bundle / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'fixture bytes')
        self.manifest = {
            'format': source.FORMAT_VERSION, 'database': 'fixture_cod4', 'map': 'mp_killhouse',
            'mysql_version': '8.0.46', 'tables': {}, 'files': source.bundle_inventory(self.bundle),
        }
        save_json(self.bundle / 'manifest.json', self.manifest)

    def test_transfer_validates_every_file_before_use(self):
        self.assertEqual(migration.validate_bundle(self.bundle)['database'], 'fixture_cod4')
        (self.bundle / 'database.sql').write_bytes(b'changed snapshot')
        with self.assertRaisesRegex(ValueError, 'checksum'):
            migration.validate_bundle(self.bundle)

    def test_unlisted_files_and_links_are_rejected(self):
        extra = self.bundle / 'game/main/injected.iwd'
        extra.touch()
        with self.assertRaisesRegex(ValueError, 'inventory'):
            migration.validate_bundle(self.bundle)
        extra.unlink()
        extra.symlink_to(self.bundle / 'database.sql')
        with self.assertRaisesRegex(ValueError, 'links'):
            migration.validate_bundle(self.bundle)

    def test_runtime_retry_preserves_completed_and_operator_edited_files(self):
        instance = self.root / 'instance'
        (instance / 'migration').mkdir(parents=True)
        self.bundle.rename(instance / 'migration/bundle')
        settings = {'uid': os.getuid(), 'gid': os.getgid()}
        migration.restore_runtime(instance, settings)
        target = instance / 'runtime/mods/opencj/checkpoints/draft.a'
        migration.restore_runtime(instance, settings)
        self.assertEqual(target.read_bytes(), b'fixture bytes')
        target.write_bytes(b'new editor draft')
        with self.assertRaisesRegex(RuntimeError, 'preserved'):
            migration.restore_runtime(instance, settings)
        self.assertEqual(target.read_bytes(), b'new editor draft')

    def test_interrupted_runtime_copy_can_resume_without_publishing_partial_draft(self):
        instance = self.root / 'instance'
        (instance / 'migration').mkdir(parents=True)
        self.bundle.rename(instance / 'migration/bundle')
        settings = {'uid': os.getuid(), 'gid': os.getgid()}
        target = instance / 'runtime/mods/opencj/checkpoints/draft.a'
        def interrupted_copy(incoming, outgoing, chunk_size):
            outgoing.write(incoming.read(3))
            raise OSError('simulated interrupted copy')
        with patch.object(source.shutil, 'copyfileobj', side_effect=interrupted_copy):
            with self.assertRaisesRegex(OSError, 'interrupted'):
                migration.restore_runtime(instance, settings)
        self.assertFalse(target.exists())
        migration.restore_runtime(instance, settings)
        self.assertEqual(target.read_bytes(), b'fixture bytes')

    def test_accepted_database_cannot_be_replaced_by_retry(self):
        settings = {'migration': {'restore_state': 'importing'}, 'state': 'ready'}
        with patch.object(migration, 'run') as docker:
            with self.assertRaisesRegex(RuntimeError, 'accepted'):
                migration.reset_incomplete_restore(self.root, settings)
        docker.assert_not_called()

    def test_player_guard_prevents_source_shutdown(self):
        bundle = self.root / 'export'
        source_directory = self.root / 'source'
        source_directory.mkdir()
        selected = {'directory': str(source_directory), 'server': 'fixture-server', 'db': 'fixture-db'}
        with patch.object(source, 'select_source', return_value=selected), \
                patch.object(source, 'copy_assets'), \
                patch.object(source, 'source_status',
                             return_value={'map': 'mp_killhouse', 'players': ['AnotherPlayer']}), \
                patch.object(source, 'run') as docker:
            with self.assertRaisesRegex(RuntimeError, 'players'):
                source.export_source(source_directory, bundle, intent='rehearsal', allowed_player='Operator')
        docker.assert_not_called()

    def test_host_plan_requires_distinct_ports_and_prior_dependencies(self):
        host_plan.validate_plan({'instances': [
            {'name': 'main-eu', 'port': 28960},
            {'name': 'acceptance', 'port': 28961, 'copy_from': 'main-eu'},
            {'name': 'map-test', 'port': 28962, 'assets_from': 'main-eu'},
        ]})
        for instances in (
                [{'name': 'main-eu', 'port': 28960}, {'name': 'acceptance', 'port': 28960}],
                [{'name': 'acceptance', 'copy_from': 'main-eu'}]):
            with self.subTest(instances=instances):
                with self.assertRaises(ValueError):
                    host_plan.validate_plan({'instances': instances})

    def test_acceptance_is_a_copy_not_a_shared_connection(self):
        result = host_plan.resolve_settings(self.root, {'name': 'acceptance', 'copy_from': 'main-eu'})
        self.assertEqual(result['database']['mode'], 'new')
        self.assertEqual(result['migration']['intent'], 'rehearsal')
        self.assertEqual(result['migration']['source_instance'], str(self.root / 'main-eu'))

    def test_website_account_rejects_private_reads_and_writes(self):
        class WebsiteDatabase:
            def __init__(self, grants):
                self.grants = grants

            def query(self, sql):
                self.assert_query = sql
                return '\n'.join(self.grants)

        principal = "'fixture_web'@'%'"
        grants = ['GRANT USAGE ON *.* TO ' + principal]
        for table in website.web_access.WEB_READABLE_TABLES:
            grants.append('GRANT SELECT ON `fixture_cod4`.`' + table + '` TO ' + principal)
        settings = {'database': {'name': 'fixture_cod4'}}
        website.check_grants(WebsiteDatabase(grants), settings)
        for unsafe in ('SELECT ON `fixture_cod4`.`playerLogin`',
                       'INSERT ON `fixture_cod4`.`playerRuns`', 'SELECT ON *.*'):
            with self.subTest(grant=unsafe):
                with self.assertRaisesRegex(RuntimeError, 'allowlist'):
                    website.check_grants(WebsiteDatabase(grants + ['GRANT ' + unsafe + ' TO ' + principal]), settings)

    def test_backup_stream_is_complete_and_cleans_up_on_capacity_failure(self):
        target = self.root / 'dump.gz'
        payload = b'CREATE TABLE fixture(id INT);\n' * 1000
        command = [sys.executable, '-c', 'import sys; sys.stdout.buffer.write(' + repr(payload) + ')']
        with patch.object(maintenance.shutil, 'disk_usage', return_value=type('Disk', (), {'free': 1000000})()):
            with patch('maintenance.run') as cleanup:
                maintenance.compress_dump(command, target, byte_limit=100000, reserve_bytes=100,
                                          cleanup=cleanup)
                cleanup.assert_called_once()
            self.assertEqual(gzip.decompress(target.read_bytes()), payload)
            target.unlink()
            with patch('maintenance.run') as cleanup:
                with self.assertRaisesRegex(RuntimeError, 'storage limit'):
                    maintenance.compress_dump(command, target, byte_limit=10, reserve_bytes=100,
                                              cleanup=cleanup)
                cleanup.assert_called_once()

    def test_backup_retention_keeps_last_success_and_refuses_foreign_files(self):
        backups = self.root / 'backups'
        backups.mkdir()
        for day in range(1, 5):
            (backups / f'2026010{day}T033000Z.sql.gz').write_bytes(b'backup')
        policy = {'keep': 2, 'max_gib': 2}
        maintenance.prune_backups(backups, policy)
        self.assertEqual([p.name for p in maintenance.retained_backups(backups)],
                         ['20260103T033000Z.sql.gz', '20260104T033000Z.sql.gz'])
        maintenance.prune_backups(backups, {**policy, 'keep': 1})
        self.assertEqual(len(maintenance.retained_backups(backups)), 1)
        (backups / 'unrelated.txt').touch()
        with self.assertRaisesRegex(RuntimeError, 'preserved'):
            maintenance.prune_backups(backups, policy)
        self.assertTrue((backups / '20260104T033000Z.sql.gz').exists())

    def test_maintenance_uses_amsterdam_and_only_database_owner_backs_up(self):
        self.assertEqual(maintenance.calendar('05:00'), '*-*-* 05:00:00 Europe/Amsterdam')
        with self.assertRaises(ValueError):
            maintenance.calendar('25:00')
        with self.assertRaisesRegex(ValueError, 'Boolean'):
            maintenance.validate_updates({'enabled': 'false'})
        with self.assertRaisesRegex(ValueError, 'owning'):
            maintenance.backup_policy({'database': {'mode': 'existing'}, 'backups': {'enabled': True}})
        policy = maintenance.backup_policy({'database': {'mode': 'new'}, 'backups': {'enabled': True}})
        self.assertEqual((policy['keep'], policy['max_gib'], policy['reserve_gib']), (7, 2, 2))


    def test_console_status_uses_real_map_and_includes_connecting_players(self):
        response = ("hostname: fixture\nmap     : mp_killhouse\n\n"
                    "num score ping playerid steamid name lastmsg address qport rate\n"
                    "--- ----- ---- -------- ------- ---- ------- ------- ----- ----\n"
                    "0 10 42 123 456 ^2Operator^7 5 127.0.0.1:1234 1234 25000\n"
                    "1 0 CNCT 0 0 Another Player^7 7 127.0.0.1:4321 4321 25000\n"
                    "\nSV packet 127.0.0.1:1234 getstatus\n]echo OPENCJ_END_fixture\n")
        self.assertEqual(source.parse_console_status(response),
                         {'map': 'mp_killhouse', 'players': ['Operator', 'Another Player']})
        with self.assertRaisesRegex(RuntimeError, 'status'):
            source.parse_console_status(response.replace('1 0 CNCT 0 0', 'truncated'))
        self.assertEqual(source.console_text(b']\b \bOPENCJ_END_fixture\x1b[0m\r\n'),
                         'OPENCJ_END_fixture\n')

    def test_source_selection_excludes_oneoffs_and_resolves_compatibility_paths(self):
        directory = self.root / 'source'
        directory.mkdir()
        (directory / 'compose.json').touch()
        alias = self.root / 'compatibility-source'
        alias.symlink_to(directory, target_is_directory=True)
        save_json(directory / 'installation.json', {
            'instance_dir': str(directory), 'state': 'ready', 'project': 'fixture-source',
            'database': {'mode': 'new', 'name': 'fixture_cod4'}, 'source_revision': 'fixture-revision',
        })
        containers = {}
        for name, oneoff in [('game', 'False'), ('oneoff', 'True'), ('database', 'False')]:
            containers[name] = {'Id': name, 'Config': {'Labels': {
                'com.docker.compose.oneoff': oneoff,
                'com.docker.compose.project.config_files': str(alias / 'compose.json'),
            }}, 'Mounts': [{'Destination': '/game', 'Source': '/fixture/game'},
                          {'Destination': '/mod-assets', 'Source': '/fixture/mod'}]}
        def selected_ids(command):
            return 'game\noneoff' if command[-1] == 'server' else 'database'
        with patch.object(source, 'run', side_effect=selected_ids), \
                patch.object(source, 'inspect_container', side_effect=containers.__getitem__):
            selected = source.select_source(alias)
        self.assertEqual((selected['server'], selected['db']), ('game', 'database'))


if __name__ == '__main__':
    unittest.main()
