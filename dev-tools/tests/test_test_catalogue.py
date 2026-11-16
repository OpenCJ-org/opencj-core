"""Discovery must reject missing coverage and unsafe automatic test selection."""

import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "test_runner", Path(__file__).resolve().parents[1] / "scripts/test.py"
)
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class CatalogueTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        tests = self.root / "dev-tools/tests"
        tests.mkdir(parents=True)
        (tests / "test_example.py").write_text("import unittest\n")
        self.group = {
            "id": "example", "category": "portable", "mode": "unit",
            "description": "Synthetic unit test.", "requires": "Python.",
            "effects": "None.", "commands": [],
            "files": ["dev-tools/tests/test_example.py"],
        }
        self.save()

    def save(self):
        (self.root / runner.CATALOGUE).write_text(json.dumps({
            "version": 1, "groups": [self.group],
        }))

    def test_new_test_must_be_catalogued(self):
        (self.root / "dev-tools/tests/test_forgotten.py").write_text("")
        with self.assertRaisesRegex(ValueError, "unlisted"):
            runner.load_catalogue(self.root)

    def test_deleted_entry_fails(self):
        (self.root / self.group["files"][0]).unlink()
        with self.assertRaisesRegex(ValueError, "Missing test file"):
            runner.load_catalogue(self.root)

    def test_ignored_experiment_is_not_discovered(self):
        (self.root / ".gitignore").write_text("dev-tools/tests/local/\n")
        local = self.root / "dev-tools/tests/local"
        local.mkdir()
        (local / "test_experiment.py").write_text("raise RuntimeError('not a test')\n")
        self.assertEqual(len(runner.load_catalogue(self.root)), 1)

    def test_component_test_must_be_catalogued(self):
        component = self.root / "component"
        component.mkdir()
        (component / "test_component.py").write_text("")
        with self.assertRaisesRegex(ValueError, "component/test_component.py"):
            runner.load_catalogue(self.root)

    def test_paths_cannot_escape_checkout(self):
        self.group["files"] = ["../outside.py"]
        self.save()
        with self.assertRaisesRegex(ValueError, "inside the repository"):
            runner.load_catalogue(self.root)

    def test_nonportable_and_unknown_selection_fail_before_execution(self):
        integration = dict(self.group, id="database", category="integration")
        for selection in [["example", "database"], ["example", "typo"]]:
            with self.assertRaises(ValueError):
                runner.select_portable([self.group, integration], selection)

    def test_zero_discovered_tests_fail(self):
        with self.assertRaisesRegex(ValueError, "No unit tests"):
            runner.run_unit(self.root / self.group["files"][0])

    def test_failed_process_stops_the_run(self):
        failed = subprocess.CompletedProcess([], 7)
        with patch.object(runner.subprocess, "run", return_value=failed) as process:
            self.assertEqual(runner.run_portable([self.group, self.group], self.root), 1)
        process.assert_called_once()


if __name__ == "__main__":
    unittest.main()
