"""Persistent mysql CLI connection; credentials stay inside Docker."""

import os
import re
import selectors
import subprocess
import time
import uuid


OUTPUT_CHUNK_BYTES = 64 * 1024
CLIENT_EXIT_TIMEOUT_SECONDS = 5


class MySQL:
    def __init__(self, container, database, runtime=False, *, command=None):
        if command is None and not container:
            raise ValueError("A database container or explicit client command is required")
        for value in (container or "client", database):
            if not re.fullmatch(r"[A-Za-z0-9_-]+", value):
                raise ValueError("Invalid container/database identifier")
        identity = (
            'MYSQL_PWD="${MYSQL_PASSWORD:-$(cat \"${MYSQL_PASSWORD_FILE:-$OPENCJ_GAME_PASSWORD_FILE}\")}" exec mysql -u "${MYSQL_USER:-$OPENCJ_GAME_USER}"'
            if runtime
            else 'MYSQL_PWD="${MYSQL_ROOT_PASSWORD:-$(cat \"$MYSQL_ROOT_PASSWORD_FILE\")}" exec mysql -u root'
        )
        client_command = command or [
            "docker",
            "exec",
            "-i",
            container,
            "sh",
            "-c",
            identity
            + " --batch --raw --skip-column-names --unbuffered --binary-as-hex "
            + database,
        ]
        self.process = subprocess.Popen(
            client_command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            bufsize=0,
        )
        self.pending = b""
        self.closed = False
        self.selector = None
        try:
            # Read replies while sending large scripts: either pipe can otherwise block the other.
            os.set_blocking(self.process.stdin.fileno(), False)
            self.selector = selectors.DefaultSelector()
            self.selector.register(self.process.stdout, selectors.EVENT_READ, "output")
        except BaseException:
            self.close()
            raise

    def query(self, sql, timeout=180):
        """Return complete rows up to this query's marker; any failure closes the session."""
        if self.closed:
            raise RuntimeError("MySQL session is closed")
        marker = "OCJ_SQL_END_" + uuid.uuid4().hex
        payload = ("DELIMITER ;\n" + sql + "\nDELIMITER ;\nSELECT '" + marker + "';\n").encode()
        unsent = memoryview(payload)
        lines = []
        deadline = time.monotonic() + timeout
        try:
            self.selector.register(self.process.stdin, selectors.EVENT_WRITE, "input")
            while True:
                while b"\n" in self.pending:
                    line, self.pending = self.pending.split(b"\n", 1)
                    line = line.decode().rstrip("\r")
                    if line == marker:
                        return "\n".join(lines)
                    lines.append(line)

                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("MySQL query timed out")
                events = self.selector.select(remaining)
                if not events:
                    raise TimeoutError("MySQL query timed out")
                for event, _ in events:
                    if event.data == "input":
                        written = self.process.stdin.write(unsent)
                        if written is None:
                            continue
                        if written == 0:
                            raise BrokenPipeError("MySQL input closed")
                        unsent = unsent[written:]
                        if not unsent:
                            self.selector.unregister(self.process.stdin)
                    else:
                        block = os.read(self.process.stdout.fileno(), OUTPUT_CHUNK_BYTES)
                        if not block:
                            # A client can exit halfway through an error line; keep that diagnostic.
                            if self.pending:
                                lines.append(self.pending.decode(errors="replace"))
                            raise RuntimeError("\n".join(lines) or "MySQL connection closed")
                        self.pending += block
        except BaseException:
            self.close()
            raise

    def close(self):
        """Release both pipes and the selector, and reap the client even after failed setup."""
        if self.closed:
            return
        self.closed = True
        try:
            self.process.stdin.close()
            if self.process.poll() is None:
                try:
                    self.process.wait(timeout=CLIENT_EXIT_TIMEOUT_SECONDS)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait()
        finally:
            self.process.stdout.close()
            if self.selector is not None:
                self.selector.close()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()
