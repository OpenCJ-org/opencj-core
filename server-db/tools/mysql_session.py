"""Persistent mysql CLI connection; credentials stay inside Docker."""

import os
import re
import selectors
import subprocess
import time
import uuid


class MySQL:
    def __init__(self, container, database, runtime=False):
        for value in (container, database):
            if not re.fullmatch(r"[A-Za-z0-9_-]+", value):
                raise ValueError("Invalid container/database identifier")
        identity = (
            'MYSQL_PWD="$MYSQL_PASSWORD" exec mysql -u "$MYSQL_USER"'
            if runtime
            else 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -u root'
        )
        self.process = subprocess.Popen(
            [
                "docker",
                "exec",
                "-i",
                container,
                "sh",
                "-c",
                identity
                + " --batch --raw --skip-column-names --unbuffered --binary-as-hex "
                + database,
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            bufsize=0,
        )
        self.pending = b""
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)

    def query(self, sql, timeout=180):
        marker = "OCJ_SQL_END_" + uuid.uuid4().hex
        self.process.stdin.write(
            ("DELIMITER ;\n" + sql + "\nDELIMITER ;\nSELECT '" + marker + "';\n").encode()
        )
        lines = []
        deadline = time.monotonic() + timeout
        while True:
            while b"\n" in self.pending:
                line, self.pending = self.pending.split(b"\n", 1)
                line = line.decode().rstrip("\r")
                if line == marker:
                    return "\n".join(lines)
                lines.append(line)
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not self.selector.select(remaining):
                self.close()
                raise TimeoutError("MySQL query timed out")
            block = os.read(self.process.stdout.fileno(), 65536)
            if not block:
                error = "\n".join(lines)
                self.close()
                raise RuntimeError(error or "MySQL connection closed")
            self.pending += block

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.selector.close()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()
