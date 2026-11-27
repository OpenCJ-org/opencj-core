"""Owned Steam downloads: private credentials, completion checks and selective asset publication."""

import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'setup'))
import configuration
import maintenance
import steam_assets


class SteamSetupTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.download = self.root / 'download'
        (self.download / 'steamapps').mkdir(parents=True)
        self.manifest = self.download / 'steamapps/appmanifest_7940.acf'
        self.manifest.write_text('"AppState" { "appid" "7940" "StateFlags" "4" "buildid" "1234" }')
        for index in range(14):
            self.write('main/iw_' + str(index).zfill(2) + '.iwd', b'owned fixture asset')
        for filename in ('common_mp.ff', 'localized_common_mp.ff', 'mp_killhouse.ff'):
            self.write('zone/english/' + filename, b'owned fixture fastfile')

    def write(self, name, contents):
        target = self.download / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(contents)

    def test_steam_runs_without_root_or_host_credentials_and_orders_login_correctly(self):
        command = steam_assets.steam_command('fixture-image', self.root / 'home', self.download,
                                             'fixture-download', 'fixture_account')
        self.assertIn('65534:65534', command)
        self.assertIn('--read-only', command)
        self.assertEqual(command[command.index('--log-driver') + 1], 'none')
        self.assertLess(command.index('+force_install_dir'), command.index('+login'))
        self.assertIn('windows', command)
        self.assertNotIn('/var/run/docker.sock', ' '.join(command))
        self.assertNotIn('password', ' '.join(command))
        self.assertIn('validate', command)

    def test_zero_exit_cannot_substitute_for_a_completed_steam_download(self):
        self.assertEqual(steam_assets.validate_download(self.download), '1234')
        self.manifest.write_text('"appid" "7940" "StateFlags" "6"')
        with self.assertRaisesRegex(RuntimeError, 'incomplete'):
            steam_assets.validate_download(self.download)
        self.manifest.unlink()
        with self.assertRaisesRegex(RuntimeError, 'did not install'):
            steam_assets.validate_download(self.download)

    def test_expected_multiplayer_assets_are_required(self):
        (self.download / 'zone/english/mp_killhouse.ff').unlink()
        with self.assertRaisesRegex(RuntimeError, 'mp_killhouse'):
            steam_assets.validate_download(self.download)

    def test_publication_excludes_account_files_single_player_and_upstream_engine(self):
        self.write('config/loginusers.vdf', b'private steam login')
        self.write('main/video/private.bik', b'unneeded video')
        support = self.root / 'support.zip'
        with zipfile.ZipFile(support, 'w') as archive:
            for name in (*steam_assets.SUPPORT_FILES, 'readme.txt', 'cod4x18_dedrun'):
                archive.writestr(steam_assets.SUPPORT_PREFIX + '/' + name, b'upstream fixture support')
        target = self.root / 'published'
        steam_assets.publish_game(self.root, target, {'source': 'fixture'},
                                  {'cod4x-support': support}, self.download)
        self.assertTrue((target / 'main/iw_00.iwd').is_file())
        self.assertTrue((target / 'steam_api.so').is_file())
        self.assertTrue((target / 'licenses/cod4x-support-readme.txt').is_file())
        self.assertFalse((target / 'steamapps').exists())
        self.assertFalse((target / 'config').exists())
        self.assertFalse((target / 'main/video').exists())
        self.assertFalse((target / 'cod4x18_dedrun').exists())
        sources = json.loads((target / 'licenses/asset-sources.json').read_text())
        self.assertEqual(sources['steam_build'], '1234')

    def test_token_is_validated_hidden_and_redacted_from_alerts(self):
        token = 'a' * 32
        with patch.object(configuration.getpass, 'getpass', return_value=token), patch('builtins.print') as printed:
            self.assertEqual(configuration.collect_auth_token(), token)
        self.assertNotIn(token, str(printed.call_args_list))
        self.assertNotIn(token, maintenance.redact_log('token=' + token, {'auth_token': token}))
        with self.assertRaisesRegex(ValueError, '32'):
            configuration.validate_auth_token('bad; token')

    def test_steam_asset_wizard_never_asks_for_a_password(self):
        with patch.object(configuration, 'ask', return_value='steamcmd'), \
                patch.object(configuration, 'prompt') as prompt, patch('builtins.print'):
            self.assertEqual(configuration.collect_asset_input('game'), 'steamcmd')
        prompt.assert_not_called()


if __name__ == '__main__':
    unittest.main()
