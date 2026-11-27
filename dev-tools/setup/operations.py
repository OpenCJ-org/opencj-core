"""Bounded private subprocesses and atomic installation records."""

from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

CONTROL_TIMEOUT_SECONDS = 180
BUILD_TIMEOUT_SECONDS = 1800
TRANSFER_TIMEOUT_SECONDS = 7200
MIGRATION_FREE_RESERVE_BYTES = 2 * 1024 ** 3


def run(command, *, timeout=CONTROL_TIMEOUT_SECONDS, log=None, stdin=None):
    """Keep command output private, including database diagnostics and credentials."""
    if log:
        with Path(log).open('ab') as output:
            result = subprocess.run(command, stdin=stdin, stdout=output,
                                    stderr=subprocess.STDOUT, timeout=timeout)
    else:
        result = subprocess.run(command, stdin=stdin, capture_output=True, timeout=timeout)
    if result.returncode:
        detail = f'; see private log {log}' if log else ''
        raise RuntimeError(f'{command[0]} {command[1]} failed{detail}')
    if not log:
        return result.stdout.decode().strip()
    return ''


def write_private(path, text, *, owner=None):
    """Atomically replace an owner-only record, never a partially written manifest."""
    descriptor, temporary_name = tempfile.mkstemp(prefix='.' + path.name + '-', dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, 'w') as output:
            output.write(text)
            output.flush()
            os.fsync(output.fileno())
        if owner and os.getuid() == 0:
            os.chown(temporary, *owner)
        os.replace(temporary, path)
        # Persist the journal's rename before the caller changes service/write ownership.
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        temporary.unlink(missing_ok=True)


def read_json(path):
    return json.loads(Path(path).read_text())


def save_json(path, value):
    write_private(Path(path), json.dumps(value, indent=2) + '\n')


class OperationInProgress(RuntimeError):
    """Another controller owns the installation lock."""


@contextmanager
def operation_lock(path):
    """A lost connection must not allow a second process to overlap the same operation."""
    with Path(path).open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise OperationInProgress('Another operation still owns this installation; retry after it finishes') from None
        yield


def inspect_container(name):
    containers = read_json_output(run(['docker', 'inspect', name]))
    if len(containers) != 1:
        raise RuntimeError('Expected exactly one selected container')
    return containers[0]


def read_json_output(output):
    return json.loads(output)


def require_migration_space(directory, incoming_bytes):
    """Leave working space for databases/services when staging a large migration copy."""
    if incoming_bytes < 0:
        raise ValueError('Invalid migration size estimate')
    if shutil.disk_usage(directory).free < incoming_bytes + MIGRATION_FREE_RESERVE_BYTES:
        raise RuntimeError('Insufficient migration space; preserve at least 2 GiB free beyond incoming files')
