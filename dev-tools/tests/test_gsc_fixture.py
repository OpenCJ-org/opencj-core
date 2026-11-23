"""Check that an isolated GSC run cannot report success while its container remains."""

import contextlib
import io
import json
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import gsc_fixture


class FixtureCleanupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.home = self.root / "dev-tools/local/owned-fixture"
        self.home.mkdir(parents=True)
        self.engine = self.root / "engine"
        self.engine.write_bytes(b"fixture engine")
        self.options = SimpleNamespace(
            binary="/workspace/engine",
            engine=self.engine,
            baseline=False,
            completion_marker="FIXTURE COMPLETE",
        )
        root_patch = patch.object(gsc_fixture, "ROOT", self.root)
        root_patch.start()
        self.addCleanup(root_patch.stop)

    def run_fixture(self, commands, log="FIXTURE COMPLETE failures=0"):
        """Mock Docker's boundary while keeping reporting and cleanup code real."""
        with patch.object(
            gsc_fixture.subprocess, "run", side_effect=commands
        ) as runner:
            with patch.object(gsc_fixture, "wait_for_fixture", return_value=log):
                with patch.object(
                    gsc_fixture, "has_libcod_mapping", return_value=False
                ):
                    with contextlib.redirect_stdout(io.StringIO()):
                        report = gsc_fixture.run_prepared_fixture(
                            self.options, self.home, "mp_killhouse", {}
                        )
        return report, runner

    def test_cleanup_failure_is_not_a_successful_run(self):
        commands = [
            subprocess.CompletedProcess([], 0, "", ""),
            subprocess.CompletedProcess([], 1, "", "daemon refused container removal"),
        ]
        with self.assertRaisesRegex(RuntimeError, "cleanup"):
            self.run_fixture(commands)
        report = json.loads((self.home / "result.json").read_text())
        self.assertFalse(report["passed"])
        self.assertFalse(report["containerRemoved"])

    def test_success_records_cleanup_and_bounds_control_calls(self):
        commands = [
            subprocess.CompletedProcess([], 0, "", ""),
            subprocess.CompletedProcess([], 0, "", ""),
        ]
        report, runner = self.run_fixture(commands)
        self.assertTrue(report["passed"])
        self.assertTrue(report["containerRemoved"])
        for call in runner.call_args_list:
            self.assertGreater(call.kwargs["timeout"], 0)
        self.assertEqual(
            runner.call_args_list[-1].args[0],
            ["docker", "rm", "-f", "opencj-owned-fixture"],
        )

    def test_script_failure_still_removes_the_owned_container(self):
        commands = [
            subprocess.CompletedProcess([], 0, "", ""),
            subprocess.CompletedProcess([], 0, "", ""),
        ]
        with self.assertRaisesRegex(RuntimeError, "failed or timed out"):
            self.run_fixture(commands, log="script runtime error")
        report = json.loads((self.home / "result.json").read_text())
        self.assertFalse(report["passed"])
        self.assertTrue(report["containerRemoved"])


if __name__ == "__main__":
    unittest.main()
