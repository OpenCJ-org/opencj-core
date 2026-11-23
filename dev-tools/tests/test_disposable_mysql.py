"""Fixture failures must not delete existing resources or leave credentials behind."""

from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import disposable_mysql


def result(stdout="", returncode=0):
    return SimpleNamespace(stdout=stdout, stderr="", returncode=returncode)


class DisposableMySQLTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        root_patch = patch.object(disposable_mysql, "ROOT", self.root)
        root_patch.start()
        self.addCleanup(root_patch.stop)
        network_patch = patch.object(
            disposable_mysql, "database_network", return_value="test-network"
        )
        network_patch.start()
        self.addCleanup(network_patch.stop)
        self.home = self.root / "dev-tools/local/test-fixture"
        self.home.mkdir(parents=True)
        self.database = disposable_mysql.DisposableMySQL(self.home, "unit")

    def test_existing_container_is_never_owned_or_removed(self):
        self.database.command = Mock(return_value=result(self.database.container))
        with self.assertRaises(RuntimeError):
            self.database.prepare()
        self.database.cleanup()
        self.assertFalse(self.database.owns_container)
        self.assertFalse(self.database.environment_file.exists())
        self.assertEqual(self.database.command.call_count, 1)

    def test_lost_launch_reply_still_removes_owned_container(self):
        def command(arguments, **kwargs):
            if arguments[:2] == ["docker", "run"]:
                raise subprocess.TimeoutExpired(arguments, 1)
            return result()

        self.database.command = Mock(side_effect=command)
        with self.assertRaises(subprocess.TimeoutExpired):
            self.database.prepare()
        self.assertTrue(self.database.owns_container)
        self.database.cleanup()
        self.assertFalse(self.database.owns_container)
        self.assertFalse(self.database.environment_file.exists())
        removed = [
            call.args[0]
            for call in self.database.command.call_args_list
            if call.args[0][:2] == ["docker", "rm"]
        ]
        self.assertEqual(removed, [["docker", "rm", "-f", "-v", self.database.container]])

    def test_cleanup_failure_still_erases_credentials(self):
        config = self.home / "database.cfg"
        self.database.private_file(self.database.environment_file, "private\n")
        self.database.write_engine_config(config)
        self.database.owns_container = True
        self.database.command = Mock(return_value=result(returncode=1))
        with self.assertRaises(RuntimeError):
            self.database.cleanup()
        self.assertTrue(self.database.owns_container)
        self.assertFalse(config.exists())
        self.assertFalse(self.database.environment_file.exists())

    def test_credentials_cannot_escape_fixture_directory(self):
        outside = self.root / "outside.cfg"
        with self.assertRaises(ValueError):
            self.database.write_engine_config(outside)
        self.assertFalse(outside.exists())

    def test_schema_export_cannot_copy_rows_or_select_another_database(self):
        for source in (
            "INSERT INTO players VALUES(1);",
            "USE gameplay;",
            "CREATE DATABASE gameplay;",
        ):
            with self.subTest(source=source):
                self.database.command = Mock(return_value=result(source))
                self.database.admin_sql = Mock()
                with patch.object(disposable_mysql, "database_container", return_value="source-db"):
                    with self.assertRaises(RuntimeError):
                        self.database.copy_schema()
                self.database.admin_sql.assert_not_called()


if __name__ == "__main__":
    unittest.main()
