"""Authoritative player checks and map preservation for managed restarts."""

import hashlib
import re
import time
from pathlib import Path

import install
import source
from assets import sha256_file
from operations import read_json, run, save_json

READY_TIMEOUT_SECONDS = 180
MAINTENANCE_RECORD = 'database-maintenance.json'
UPGRADE_FILES_RECORD = 'upgrade-files.json'


def require_available(instance):
    if (instance / MAINTENANCE_RECORD).exists():
        raise RuntimeError('Database maintenance is unfinished; rerun its restore, refresh or upgrade command first')


def active_game(instance, settings):
    """A stopped server is distinct from a running server whose status cannot be read."""
    container = install.compose(instance, settings, 'ps', '--status', 'running', '--quiet', 'server')
    if not container:
        return {'map': '', 'players': []}
    return source.source_status({'server': container})


def available_map(settings, map_name):
    if not re.fullmatch(r'[a-z0-9_]+', map_name):
        return False
    game = Path(settings['game_dir'])
    if (game / 'usermaps' / map_name / (map_name + '.ff')).is_file():
        return True
    return any((game / 'zone').glob('*/' + map_name + '.ff'))


def restore_map(instance, settings, map_name):
    """Restore the captured map after a healthy restart, refusing to displace new arrivals."""
    if not map_name:
        return
    if not available_map(settings, map_name):
        print('Previous map ' + map_name + ' is unavailable; keeping the configured start map.', flush=True)
        return
    container = install.compose(instance, settings, 'ps', '--quiet', 'server')
    deadline = time.monotonic() + READY_TIMEOUT_SECONDS
    requested = False
    while True:
        try:
            active = source.source_status({'server': container})
        except (RuntimeError, OSError) as error:
            if time.monotonic() >= deadline:
                raise RuntimeError('Console did not recover while restoring ' + map_name) from error
            time.sleep(2)
            continue
        if active['map'] == map_name:
            return
        if active['players']:
            raise RuntimeError('Players joined before map restoration; previous map was ' + map_name)
        if not requested:
            source.set_source_map(container, map_name)
            requested = True
        if time.monotonic() >= deadline:
            raise RuntimeError('Previous map did not load: ' + map_name)
        time.sleep(2)


def verify_running_files(instance, settings):
    """Check the files visible inside the recreated container, including atomic bind replacements."""
    container = install.compose(instance, settings, 'ps', '--quiet', 'server')
    for filename in ('server.cfg', 'runtime.json'):
        mounted_hash = run(['docker', 'exec', container, 'sha256sum', '/run/opencj/' + filename]).split()[0]
        if mounted_hash != sha256_file(instance / filename):
            raise RuntimeError('The running server still has an older ' + filename)


def record_configuration_write(path, text):
    """Journal each allowed old/new file hash before atomic replacement, so retries preserve operator edits."""
    pending = path.parent / 'pending-configuration.json'
    if not pending.exists():
        pending = path.parent / UPGRADE_FILES_RECORD
    if not pending.exists():
        return
    record = read_json(pending)
    if not record.get('applying'):
        return
    before = sha256_file(path) if path.exists() else None
    after = hashlib.sha256(text.encode()).hexdigest()
    receipt = record.setdefault('files', {}).setdefault(path.name, {'before': before, 'after': after})
    if before not in (receipt['before'], receipt['after']) or after != receipt['after']:
        raise RuntimeError('Configuration changed during its retry; existing files preserved')
    save_json(pending, record)


def verify_configuration_retry(instance, settings, record):
    for filename, expected in settings['managed_hashes'].items():
        receipt = record.get('files', {}).get(filename, {'before': expected, 'after': expected})
        if not (instance / filename).is_file() or sha256_file(instance / filename) not in receipt.values():
            raise RuntimeError('Configuration has operator changes; interrupted apply preserved')
