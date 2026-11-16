import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/bootstrap-db.py"
spec = importlib.util.spec_from_file_location("bootstrap_db", SCRIPT)
bootstrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)


class BootstrapTargetTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.directory = self.root / "dev-tools"
        self.directory.mkdir()
        (self.directory / ".env").write_text("COMPOSE_PROJECT_NAME=isolated-test\n")
        root_patch = patch.object(bootstrap, "ROOT", self.root)
        root_patch.start()
        self.addCleanup(root_patch.stop)

    def test_uses_running_database_from_this_checkout(self):
        with patch.object(bootstrap.subprocess, "check_output", return_value="abc123\n") as query:
            self.assertEqual(bootstrap.compose_database_container(), "abc123")
        query.assert_called_once_with(
            [
                "docker",
                "compose",
                "--env-file",
                str(self.directory / ".env"),
                "ps",
                "--status",
                "running",
                "--quiet",
                "db",
            ],
            cwd=self.directory,
            text=True,
        )

    def test_missing_or_ambiguous_database_never_falls_back(self):
        for output in ["", "abc123\ndef456\n"]:
            with self.subTest(output=output):
                with patch.object(bootstrap.subprocess, "check_output", return_value=output):
                    with self.assertRaisesRegex(RuntimeError, "one running db service"):
                        bootstrap.compose_database_container()

    def test_missing_configuration_does_not_query_docker(self):
        (self.directory / ".env").unlink()
        with patch.object(bootstrap.subprocess, "check_output") as query:
            with self.assertRaisesRegex(RuntimeError, "init first"):
                bootstrap.compose_database_container()
            query.assert_not_called()

    def test_default_check_connects_only_to_selected_database(self):
        with patch.object(bootstrap.sys, "argv", ["bootstrap-db.py", "--check"]), patch.object(
            bootstrap, "compose_database_container", return_value="isolated-db"
        ) as select, patch.object(bootstrap, "MySQL") as mysql, patch.object(
            bootstrap.migrate, "lock"
        ), patch.object(
            bootstrap, "check", return_value=25
        ):
            bootstrap.main()
        select.assert_called_once_with()
        mysql.assert_called_once_with("isolated-db", "openCJ_cod4")

    def test_explicit_container_does_not_require_compose(self):
        with patch.object(
            bootstrap.sys, "argv", ["bootstrap-db.py", "--container", "fixture-db", "--check"]
        ), patch.object(bootstrap, "compose_database_container") as select, patch.object(
            bootstrap, "MySQL"
        ) as mysql, patch.object(
            bootstrap.migrate, "lock"
        ), patch.object(
            bootstrap, "check", return_value=25
        ):
            bootstrap.main()
        select.assert_not_called()
        mysql.assert_called_once_with("fixture-db", "openCJ_cod4")


if __name__ == "__main__":
    unittest.main()
