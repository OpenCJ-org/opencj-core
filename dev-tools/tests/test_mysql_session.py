"""Exercise the persistent SQL client's transport without Docker or a database."""

from pathlib import Path
import subprocess
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "server-db/tools"))
import mysql_session

REAL_POPEN = subprocess.Popen
FAKE_CLIENT = r"""
import re
import sys

ignore_results = False
for line in sys.stdin:
    if "SELECT fixture_value" in line:
        print("fixture", flush=True)
    if "SELECT fixture_flood" in line:
        print("row" * 200, flush=True)
    if "SELECT incomplete_output" in line:
        sys.stdout.write("incomplete diagnostic")
        sys.stdout.flush()
        sys.exit(1)
    if "SELECT invalid_output" in line:
        sys.stdout.buffer.write(b"\xff\n")
        sys.stdout.flush()
    if "SELECT wait_forever" in line:
        ignore_results = True
    marker = re.search(r"OCJ_SQL_END_[a-f0-9]+", line)
    if marker and not ignore_results:
        print(marker[0], flush=True)
"""


class ShortWriter:
    """A valid pipe write may accept less than the supplied input."""

    def __init__(self, stream):
        self.stream = stream

    def write(self, data):
        return self.stream.write(data[:7])

    def close(self):
        self.stream.close()

    def fileno(self):
        return self.stream.fileno()

    @property
    def closed(self):
        return self.stream.closed


class MySQLSessionTests(unittest.TestCase):
    def setUp(self):
        self.processes = []
        self.client_program = FAKE_CLIENT
        patcher = mock.patch.object(mysql_session.subprocess, "Popen", self.start_client)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self.stop_clients)

    def start_client(self, command, **options):
        process = REAL_POPEN([sys.executable, "-u", "-c", self.client_program], **options)
        self.processes.append(process)
        return process

    def stop_clients(self):
        # Also clean up deliberately failing baseline implementations.
        for process in self.processes:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)
            for stream in (process.stdin, process.stdout):
                stream.close()

    def assert_closed(self, session):
        self.assertIsNotNone(session.process.poll(), "the client must have exited")
        self.assertTrue(session.process.stdin.closed, "the input pipe must be closed")
        self.assertTrue(session.process.stdout.closed, "the output pipe must be closed")

    def test_successive_queries_keep_one_session_and_release_its_pipes(self):
        with mysql_session.MySQL("fixture-db", "fixture_schema") as session:
            self.assertEqual(session.query("SELECT fixture_value;"), "fixture")
            self.assertEqual(session.query("SELECT fixture_value;"), "fixture")
            self.assertEqual(len(self.processes), 1)
        self.assert_closed(session)
        session.close()

    def test_context_exception_still_releases_the_client(self):
        with self.assertRaisesRegex(RuntimeError, "fixture failure"):
            with mysql_session.MySQL("fixture-db", "fixture_schema") as session:
                raise RuntimeError("fixture failure")
        self.assert_closed(session)

    def test_partial_pipe_writes_preserve_the_complete_query(self):
        with mysql_session.MySQL("fixture-db", "fixture_schema") as session:
            session.process.stdin = ShortWriter(session.process.stdin)
            self.assertEqual(session.query("SELECT fixture_value;", timeout=1), "fixture")

    def test_timeout_closes_the_session(self):
        session = mysql_session.MySQL("fixture-db", "fixture_schema")
        with self.assertRaises(TimeoutError):
            session.query("SELECT wait_forever;", timeout=0.05)
        self.assert_closed(session)

    def test_eof_preserves_a_diagnostic_without_a_final_newline(self):
        session = mysql_session.MySQL("fixture-db", "fixture_schema")
        with self.assertRaisesRegex(RuntimeError, "incomplete diagnostic"):
            session.query("SELECT incomplete_output;")
        self.assert_closed(session)

    def test_invalid_output_closes_the_session(self):
        session = mysql_session.MySQL("fixture-db", "fixture_schema")
        with self.assertRaises(UnicodeDecodeError):
            session.query("SELECT invalid_output;")
        self.assert_closed(session)

    def test_selector_setup_failure_releases_the_started_client(self):
        selector = mock.Mock()
        selector.register.side_effect = OSError("fixture selector failure")
        with mock.patch.object(mysql_session.selectors, "DefaultSelector", return_value=selector):
            with self.assertRaisesRegex(OSError, "fixture selector failure"):
                mysql_session.MySQL("fixture-db", "fixture_schema")
        self.assertIsNotNone(self.processes[0].poll())
        self.assertTrue(self.processes[0].stdin.closed)
        self.assertTrue(self.processes[0].stdout.closed)
        selector.close.assert_called_once()

    def test_large_scripts_drain_replies_while_still_sending_input(self):
        statement_count = 1000
        with mysql_session.MySQL("fixture-db", "fixture_schema") as session:
            result = session.query("SELECT fixture_flood;\n" * statement_count, timeout=5)
        rows = result.splitlines()
        self.assertEqual(len(rows), statement_count)
        self.assertEqual(rows[0], "row" * 200)
        self.assertEqual(rows[-1], "row" * 200)

    def test_timeout_also_bounds_a_blocked_input_pipe(self):
        self.client_program = "import time; time.sleep(0.2)"
        session = mysql_session.MySQL("fixture-db", "fixture_schema")
        with self.assertRaises(TimeoutError):
            session.query("SELECT " + "x" * (1024 * 1024), timeout=0.02)
        self.assert_closed(session)

    def test_closed_session_rejects_more_queries(self):
        session = mysql_session.MySQL("fixture-db", "fixture_schema")
        session.close()
        with self.assertRaisesRegex(RuntimeError, "session is closed"):
            session.query("SELECT fixture_value;")

    def test_invalid_identifiers_start_no_process(self):
        for container, database in (("bad;container", "valid"), ("valid", "bad'database")):
            with self.subTest(container=container, database=database):
                with self.assertRaises(ValueError):
                    mysql_session.MySQL(container, database)
        self.assertEqual(self.processes, [])


if __name__ == "__main__":
    unittest.main()
