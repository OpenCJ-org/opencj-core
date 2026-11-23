"""Name-rule maintenance uses synthetic terms and no external services."""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch

HELPER_PATH = Path(__file__).with_name("manage-name-rules.py")
SPEC = importlib.util.spec_from_file_location("name_rules", HELPER_PATH)
name_rules = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(name_rules)


class NameRuleTests(unittest.TestCase):
    def test_seed_merges_exceptions_without_importing_default_severity(self):
        rules = name_rules.seed_rules(
            [
                {"severity": 4, "match": "FixtureToken", "exceptions": ["Ok*"]},
                {"severity": 4, "match": "FixtureToken", "exceptions": ["Other*"]},
                {"severity": 3, "match": "DefaultEntry"},
            ]
        )
        key = (name_rules.digest("fixturetoken"), "contains")
        self.assertEqual(set(rules), {key})
        self.assertEqual(rules[key]["length"], len("fixturetoken"))
        self.assertEqual(
            rules[key]["exceptions"],
            {name_rules.digest("okfixturetoken"), name_rules.digest("otherfixturetoken")},
        )

    def test_normalization_matches_supported_name_rules(self):
        self.assertEqual(name_rules.normalize("^1F1x.tuure Token"), "fixturetoken")
        self.assertEqual(name_rules.normalize("111___@@@"), "ia")
        self.assertEqual(name_rules.normalize("___"), "")

    def test_dry_run_never_opens_database_or_prints_private_text(self):
        output = io.StringIO()
        with patch.object(name_rules.getpass, "getpass", return_value="FixtureToken"), patch.object(
            name_rules, "query_database"
        ) as database, contextlib.redirect_stdout(output):
            name_rules.main(["--add", "--dry-run"])
        database.assert_not_called()
        self.assertNotIn("FixtureToken", output.getvalue())
        self.assertNotIn(name_rules.digest("fixturetoken"), output.getvalue())
        self.assertTrue(json.loads(output.getvalue())["dryRun"])

    def test_invalid_target_is_rejected_before_reading_private_input(self):
        with patch.object(name_rules.getpass, "getpass") as prompt, patch.object(
            name_rules, "query_database"
        ) as database, contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                name_rules.main(["--add", "--database", "invalid-target"])
        prompt.assert_not_called()
        database.assert_not_called()

    def test_database_failure_does_not_disclose_submitted_query_or_stderr(self):
        result = subprocess.CompletedProcess([], 1, "", "private diagnostic")
        with patch.object(name_rules.subprocess, "run", return_value=result):
            with self.assertRaisesRegex(RuntimeError, "no submitted text was logged") as error:
                name_rules.query_database("openCJ_cod4", "synthetic private SQL")
        self.assertNotIn("private diagnostic", str(error.exception))
        self.assertNotIn("synthetic private SQL", str(error.exception))

    def test_database_timeout_reports_uncertain_outcome_without_retry(self):
        timeout = subprocess.TimeoutExpired(["docker"], 180, stderr="private diagnostic")
        with patch.object(name_rules.subprocess, "run", side_effect=timeout) as run:
            with self.assertRaisesRegex(RuntimeError, "outcome is unknown") as error:
                name_rules.query_database("openCJ_cod4", "synthetic private SQL")
        self.assertEqual(run.call_count, 1)
        self.assertEqual(run.call_args.kwargs["timeout"], name_rules.DATABASE_TIMEOUT_SECONDS)
        self.assertNotIn("private diagnostic", str(error.exception))

    def test_receipt_is_private_before_metadata_is_written(self):
        receipt = {"operation": "disable", "ruleID": 7}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "receipt.json"
            original_dump = json.dump
            observed_modes = []

            def inspect_write(value, stream, **options):
                observed_modes.append(stat.S_IMODE(os.fstat(stream.fileno()).st_mode))
                return original_dump(value, stream, **options)

            with patch.object(name_rules.json, "dump", side_effect=inspect_write):
                name_rules.write_receipt(path, receipt)
                path.chmod(0o644)
                name_rules.write_receipt(path, receipt)
            self.assertEqual(observed_modes, [0o600, 0o600])
            self.assertEqual(json.loads(path.read_text()), receipt)


if __name__ == "__main__":
    unittest.main()
