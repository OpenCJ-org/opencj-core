"""Exercise Docker attach failures without containers or database access."""

from collections import deque
from pathlib import Path
import runpy
import socket
import unittest
from unittest.mock import patch

RUNNER = runpy.run_path(str(Path(__file__).with_name("run-history-save-192.py")))
HistoryVerification = RUNNER["HistoryVerification"]


class FakeSocket:
    def __init__(self, responses, *, connect_error=None):
        self.responses = deque(responses)
        self.connect_error = connect_error
        self.sent = []
        self.closed = False
        self.saw_eof = False

    def __enter__(self):
        return self

    def __exit__(self, *exception):
        self.close()

    def settimeout(self, timeout_seconds):
        self.timeout_seconds = timeout_seconds

    def connect(self, address):
        if self.connect_error:
            raise self.connect_error

    def sendall(self, message):
        self.sent.append(message)

    def recv(self, byte_count):
        # Fail a repeated EOF read instead of hanging a regression of the old loop.
        if self.saw_eof:
            raise AssertionError("The attach loop continued after EOF")
        response = self.responses.popleft() if self.responses else b""
        if isinstance(response, Exception):
            raise response
        if not response:
            self.saw_eof = True
        return response

    def close(self):
        self.closed = True


class DockerAttachTests(unittest.TestCase):
    def setUp(self):
        # Test only console transport; the constructor intentionally owns real test files.
        self.verification = HistoryVerification.__new__(HistoryVerification)
        self.verification.container_name = "isolated-history-fixture"

    def change_map(self, connection):
        with patch.object(RUNNER["socket"], "socket", return_value=connection):
            self.verification.change_map()

    def test_fragmented_success_sends_one_map_command_and_closes(self):
        for status in (b"101 Switching Protocols", b"200 OK"):
            with self.subTest(status=status):
                connection = FakeSocket([b"HTTP/1.1 " + status + b"\r\n", b"\r\n"])
                self.change_map(connection)
                self.assertEqual(connection.sent[-1], b"map mp_killhouse\n")
                self.assertEqual(len(connection.sent), 2)
                self.assertTrue(connection.closed)

    def test_closed_header_fails_without_reading_eof_forever(self):
        connection = FakeSocket([b""])
        with self.assertRaisesRegex(RuntimeError, "closed.*header"):
            self.change_map(connection)
        self.assertEqual(len(connection.sent), 1)
        self.assertTrue(connection.closed)

    def test_header_timeout_closes_the_socket(self):
        connection = FakeSocket([socket.timeout("header timed out")])
        with self.assertRaises(socket.timeout):
            self.change_map(connection)
        self.assertTrue(connection.closed)

    def test_connection_failure_closes_the_socket(self):
        connection = FakeSocket([], connect_error=OSError("connection refused"))
        with self.assertRaises(OSError):
            self.change_map(connection)
        self.assertTrue(connection.closed)

    def test_rejected_upgrade_sends_no_command(self):
        connection = FakeSocket([b"HTTP/1.1 403 Forbidden\r\n\r\n"])
        with self.assertRaisesRegex(RuntimeError, "attach.*403"):
            self.change_map(connection)
        self.assertEqual(len(connection.sent), 1)
        self.assertTrue(connection.closed)

    def test_status_text_cannot_turn_a_server_error_into_success(self):
        connection = FakeSocket([b"HTTP/1.1 500 error-detail-200\r\n\r\n"])
        with self.assertRaisesRegex(RuntimeError, "attach.*500"):
            self.change_map(connection)
        self.assertEqual(len(connection.sent), 1)
        self.assertTrue(connection.closed)

    def test_malformed_status_line_sends_no_command(self):
        connection = FakeSocket([b"not-an-http-response\r\n\r\n"])
        with self.assertRaisesRegex(RuntimeError, "malformed status"):
            self.change_map(connection)
        self.assertEqual(len(connection.sent), 1)
        self.assertTrue(connection.closed)

    def test_unterminated_header_has_a_size_bound(self):
        connection = FakeSocket([b"x" * 4096] * 5)
        with self.assertRaisesRegex(RuntimeError, "header.*too large"):
            self.change_map(connection)
        self.assertEqual(len(connection.sent), 1)
        self.assertTrue(connection.closed)

    def test_header_has_an_overall_deadline(self):
        connection = FakeSocket([b"HTTP/1.1 "])
        with patch.object(RUNNER["time"], "monotonic", side_effect=[0, 3]):
            with self.assertRaisesRegex(TimeoutError, "header"):
                self.change_map(connection)
        self.assertTrue(connection.closed)


if __name__ == "__main__":
    unittest.main()
