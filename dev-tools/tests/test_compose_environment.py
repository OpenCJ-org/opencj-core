"""Prerequisite checks must not silently select another installation."""

import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import compose_environment as environment


class ComposeEnvironmentTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        (self.root / "dev-tools").mkdir()
        (self.root / "dev-tools/.env").write_text("COMPOSE_PROJECT_NAME=fixture-project\n")
        root_patch = patch.object(environment, "ROOT", self.root)
        root_patch.start()
        self.addCleanup(root_patch.stop)
        environment.database_container.cache_clear()
        environment.database_network.cache_clear()
        self.addCleanup(environment.database_container.cache_clear)
        self.addCleanup(environment.database_network.cache_clear)

    def test_selects_and_caches_this_projects_running_database(self):
        with patch.object(
            environment.subprocess, "check_output", return_value="fixture-id\n"
        ) as query:
            self.assertEqual(environment.database_container(), "fixture-id")
            self.assertEqual(environment.database_container(), "fixture-id")
        query.assert_called_once_with(
            [
                "docker",
                "compose",
                "--env-file",
                str(self.root / "dev-tools/.env"),
                "ps",
                "--status",
                "running",
                "--quiet",
                "db",
            ],
            cwd=self.root / "dev-tools",
            text=True,
        )

    def test_missing_or_ambiguous_database_has_no_fallback(self):
        for response in ("", "first\nsecond\n"):
            with self.subTest(response=response):
                with patch.object(environment.subprocess, "check_output", return_value=response):
                    with self.assertRaisesRegex(RuntimeError, "one running db service"):
                        environment.database_container()

    def test_missing_configuration_does_not_query_docker(self):
        (self.root / "dev-tools/.env").unlink()
        with patch.object(environment.subprocess, "check_output") as query:
            with self.assertRaisesRegex(RuntimeError, "separate test installation"):
                environment.database_container()
            query.assert_not_called()

    def test_network_accepts_a_custom_project_name(self):
        with patch.object(
            environment, "database_container", return_value="fixture-id"
        ), patch.object(
            environment.subprocess, "check_output", return_value=json.dumps({"custom_default": {}})
        ) as query:
            self.assertEqual(environment.database_network(), "custom_default")
        self.assertEqual(query.call_args.args[0][-1], "fixture-id")

    def test_missing_or_ambiguous_network_is_rejected(self):
        for networks in ({}, {"one": {}, "two": {}}):
            with self.subTest(networks=networks):
                with patch.object(
                    environment, "database_container", return_value="fixture-id"
                ), patch.object(
                    environment.subprocess, "check_output", return_value=json.dumps(networks)
                ):
                    with self.assertRaisesRegex(RuntimeError, "one network"):
                        environment.database_network()

    def test_workspace_file_is_translated_to_the_container_mount(self):
        binary = self.root / "test-engine"
        binary.touch()
        self.assertEqual(environment.workspace_path(binary), "/workspace/test-engine")

    def test_missing_and_external_inputs_are_rejected(self):
        with tempfile.TemporaryDirectory() as outside:
            external = Path(outside) / "test-engine"
            external.touch()
            for path in (external, self.root / "missing", self.root):
                with self.subTest(path=path):
                    with self.assertRaises(ValueError):
                        environment.workspace_file(path)
            link = self.root / "outside-link"
            link.symlink_to(external)
            with self.assertRaises(ValueError):
                environment.workspace_file(link)

    def test_cpu_default_uses_two_allowed_cores(self):
        with patch.object(environment.os, "sched_getaffinity", return_value={2, 7, 9}):
            self.assertEqual(environment.capacity_cpu_set(), "2,7")

    def test_cpu_selection_accepts_valid_pairs_and_ranges(self):
        with patch.object(environment.os, "sched_getaffinity", return_value={0, 1, 3}):
            self.assertEqual(environment.capacity_cpu_set("3,0"), "0,3")
            self.assertEqual(environment.capacity_cpu_set("0-1"), "0,1")

    def test_invalid_cpu_selection_fails_before_running_fixtures(self):
        with patch.object(environment.os, "sched_getaffinity", return_value={0, 1, 3}):
            for value in ("4,5", "0", "0,0", "0-3", "1-0", "0,1,3", "0-999999999", "abc", ""):
                with self.subTest(value=value):
                    with self.assertRaises(ValueError):
                        environment.capacity_cpu_set(value)
        with patch.object(environment.os, "sched_getaffinity", return_value={0}):
            with self.assertRaisesRegex(ValueError, "at least two"):
                environment.capacity_cpu_set()


if __name__ == "__main__":
    unittest.main()
