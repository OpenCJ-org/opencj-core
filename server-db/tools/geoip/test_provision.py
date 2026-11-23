"""Check private secret handling and validation without a database or real credentials."""

import contextlib
import io
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import provision

SYNTHETIC_SECRET = "synthetic_secret_used_only_by_the_unit_fixture"


class ProvisionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.secret_file = self.directory / "private" / "password"
        self.account_exists = False
        self.database = mock.MagicMock()
        self.database.__enter__.return_value = self.database
        self.database.query.side_effect = self.query
        patcher = mock.patch.object(provision, "MySQL", return_value=self.database)
        self.connect = patcher.start()
        self.addCleanup(patcher.stop)
        patcher = mock.patch.object(
            provision.secrets, "token_urlsafe", return_value=SYNTHETIC_SECRET
        )
        patcher.start()
        self.addCleanup(patcher.stop)

    def query(self, sql):
        if "mysql.user" in sql:
            return "1" if self.account_exists else "0"
        return "0"

    def write_existing_secret(self, mode=0o600, content=SYNTHETIC_SECRET):
        self.secret_file.parent.mkdir(mode=0o700)
        self.secret_file.write_text(content + "\n")
        self.secret_file.chmod(mode)

    def test_invalid_gameplay_account_has_no_database_or_file_effects(self):
        with self.assertRaises(ValueError):
            provision.provision(
                "fixture-db", "fixture_schema", self.secret_file, gameplay_account="invalid'account"
            )
        self.connect.assert_not_called()
        self.assertFalse(self.secret_file.parent.exists())

    def test_invalid_database_or_updater_account_starts_no_session(self):
        for database, account in (("invalid'database", "geoip_fixture"), ("valid", "not_geoip")):
            with self.subTest(database=database, account=account):
                with self.assertRaises(ValueError):
                    provision.provision("fixture-db", database, self.secret_file, account=account)
        self.connect.assert_not_called()
        self.assertFalse(self.secret_file.parent.exists())

    def test_new_secret_is_private_and_never_printed(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            result = provision.provision("fixture-db", "fixture_schema", self.secret_file)
        self.assertEqual(result, self.secret_file)
        self.assertEqual(self.secret_file.read_text(), SYNTHETIC_SECRET + "\n")
        self.assertEqual(self.secret_file.stat().st_mode & 0o777, 0o600)
        self.assertEqual(output.getvalue(), "")

    def test_existing_account_keeps_its_secret(self):
        self.account_exists = True
        self.write_existing_secret()
        provision.provision("fixture-db", "fixture_schema", self.secret_file)
        self.assertEqual(self.secret_file.read_text(), SYNTHETIC_SECRET + "\n")
        provision.secrets.token_urlsafe.assert_not_called()
        queries = [call.args[0] for call in self.database.query.call_args_list]
        self.assertFalse(any("CREATE USER" in query or "ALTER USER" in query for query in queries))

    def test_missing_secret_for_existing_account_does_not_reset_it(self):
        self.account_exists = True
        with self.assertRaisesRegex(ValueError, "refusing a silent password reset"):
            provision.provision("fixture-db", "fixture_schema", self.secret_file)
        self.assertFalse(self.secret_file.exists())
        provision.secrets.token_urlsafe.assert_not_called()

    def test_publicly_readable_secret_is_rejected(self):
        self.write_existing_secret(mode=0o644)
        with self.assertRaisesRegex(ValueError, "mode 0600"):
            provision.provision("fixture-db", "fixture_schema", self.secret_file)

    def test_invalid_secret_format_is_rejected(self):
        self.write_existing_secret(content="invalid-fixture")
        with self.assertRaisesRegex(ValueError, "secret format"):
            provision.provision("fixture-db", "fixture_schema", self.secret_file)

    def test_unignored_repository_path_is_rejected_before_database_access(self):
        (self.directory / ".git").mkdir()
        not_ignored = mock.Mock(returncode=1)
        with mock.patch.object(provision.subprocess, "run", return_value=not_ignored):
            with self.assertRaisesRegex(ValueError, "not ignored"):
                provision.provision("fixture-db", "fixture_schema", self.secret_file)
        self.connect.assert_not_called()
        self.assertFalse(self.secret_file.exists())


if __name__ == "__main__":
    unittest.main()
