"""Create a resumable migration bundle while preserving the source installation."""

import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import subprocess
import sys
import time

from assets import sha256_file
from operations import inspect_container, operation_lock, read_json, run, save_json
from operations import TRANSFER_TIMEOUT_SECONDS, require_migration_space

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'server-db/tools'))
from mysql_session import MySQL
from runtime_access import quote_identifier, quote_literal

SOURCE_START_TIMEOUT_SECONDS = 180
FILE_CHUNK_BYTES = 1024 * 1024
# Version 2 records logical table digests. Version 1 used CHECKSUM TABLE, which
# reports a mismatch after any restore that rounds FLOAT values.
FORMAT_VERSION = 2
# SHA-256 is 64 hex digits; summing it as four 16-digit lanes keeps every partial
# value inside MySQL's 64-bit CONV/BIGINT UNSIGNED range.
DIGEST_LANE_COUNT = 4
DIGEST_LANE_HEX_DIGITS = 16
INVENTORY_QUERY_TIMEOUT_SECONDS = 600


def select_source(directory):
    """Resolve only the explicitly selected development or installed Compose project."""
    directory = directory.resolve()
    record = directory / 'installation.json'
    if record.is_file():
        settings = read_json(record)
        if settings.get('instance_dir') != str(directory) or settings.get('state') != 'ready':
            raise ValueError('Source must be a ready installation at its original path')
        if settings['database']['mode'] != 'new':
            raise ValueError('Select the installation that owns the database')
        compose = ['docker', 'compose', '-p', settings['project'], '-f', str(directory / 'compose.json')]
        runtime = directory / 'runtime'
        database = settings['database']['name']
    else:
        if not (directory / '.env').is_file() or not (directory / 'compose.yaml').is_file():
            raise ValueError('Select an installed instance or its development dev-tools directory')
        compose = ['docker', 'compose', '--project-directory', str(directory),
                   '--env-file', str(directory / '.env'), '-f', str(directory / 'compose.yaml')]
        runtime = directory / 'local/runtime'
        database = 'openCJ_cod4'
    containers = {}
    for service in ('server', 'db'):
        identifiers = run([*compose, 'ps', '--all', '--quiet', service]).splitlines()
        expected_file = (directory / ('compose.json' if record.is_file() else 'compose.yaml')).resolve()
        selected = []
        for identifier in identifiers:
            metadata = inspect_container(identifier)
            labels = metadata['Config']['Labels']
            # Compose ps includes one-off development/test containers with the
            # same service label. They are never migration source services.
            if str(labels.get('com.docker.compose.oneoff', '')).lower() != 'false':
                continue
            configured_files = labels.get('com.docker.compose.project.config_files', '').split(',')
            if expected_file not in {Path(path).resolve() for path in configured_files if path}:
                continue
            selected.append(metadata)
        if len(selected) != 1:
            raise RuntimeError('Expected one owned source ' + service + ' service container')
        containers[service] = selected[0]
    mounts = {item['Destination']: item['Source'] for item in containers['server']['Mounts']}
    return {
        'directory': str(directory), 'runtime': str(runtime.resolve()), 'database': database,
        'server': containers['server']['Id'], 'db': containers['db']['Id'],
        'game': mounts['/game'], 'mod': mounts['/mod-assets'],
        'core_revision': settings['source_revision'] if record.is_file() else
                         run(['git', '-C', str(directory.parent), 'rev-parse', 'HEAD']),
    }


def console_text(data):
    """Apply the engine terminal's backspace redraws before interpreting output lines."""
    text = re.sub(r'\x1b\[[0-9;]*[A-Za-z]', '', data.decode('utf-8', errors='replace'))
    visible = []
    for character in text:
        if character == '\b':
            if visible and visible[-1] != '\n':
                visible.pop()
        elif character != '\r':
            visible.append(character)
    return ''.join(visible)


def console_output(container, command):
    """Read a bounded, freshly delimited console response without signaling the game."""
    metadata = inspect_container(container)
    configuration = metadata['Config']
    if not configuration.get('Tty') or not configuration.get('OpenStdin') or configuration.get('StdinOnce'):
        raise RuntimeError('Source requires a persistent TTY console for safe maintenance checks')
    endpoint = os.environ.get('DOCKER_HOST') or run(
        ['docker', 'context', 'inspect', '--format', '{{.Endpoints.docker.Host}}'])
    if not endpoint.startswith('unix://'):
        raise RuntimeError('Source maintenance requires its local Docker Unix socket')
    if not re.fullmatch(r'[0-9a-f]{12,64}', metadata['Id']):
        raise RuntimeError('Invalid source container identity')
    nonce = secrets.token_hex(16)
    begin = 'OPENCJ_BEGIN_' + nonce
    end = 'OPENCJ_END_' + nonce
    deadline = time.monotonic() + 20
    maximum_bytes = 256 * 1024
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(5)
        connection.connect(endpoint.removeprefix('unix://'))
        request = ('POST /containers/' + metadata['Id'] +
                   '/attach?stream=1&stdin=1&stdout=1&stderr=1 HTTP/1.1\r\n'
                   'Host: docker\r\nConnection: Upgrade\r\nUpgrade: tcp\r\nContent-Length: 0\r\n\r\n')
        connection.sendall(request.encode())
        received = bytearray()
        while b'\r\n\r\n' not in received:
            chunk = connection.recv(4096)
            if not chunk:
                raise RuntimeError('Docker closed the console handshake')
            received.extend(chunk)
            if len(received) > 16384:
                raise RuntimeError('Docker console handshake is too large')
        header, body = bytes(received).split(b'\r\n\r\n', 1)
        if header.split(b'\r\n', 1)[0].split()[1] not in (b'101', b'200'):
            raise RuntimeError('Docker refused console attachment')
        connection.sendall(('echo ' + begin + '\n' + command + '\necho ' + end + '\n').encode())
        received = bytearray(body)
        while time.monotonic() < deadline:
            lines = [line.strip() for line in console_text(received).splitlines()]
            if begin in lines and end in lines:
                return '\n'.join(lines[lines.index(begin) + 1:lines.index(end)])
            connection.settimeout(max(0.1, deadline - time.monotonic()))
            chunk = connection.recv(8192)
            if not chunk:
                raise RuntimeError('Docker closed the console before the response completed')
            received.extend(chunk)
            if len(received) > maximum_bytes:
                raise RuntimeError('Console response exceeded its size limit')
    raise RuntimeError('Console response exceeded its deadline')


def parse_console_status(text):
    """Include all connected/connecting clients, including those hidden from public status."""
    lines = [re.sub(r'\^[0-9]', '', line).strip() for line in text.splitlines()]
    maps = [match.group(1) for line in lines if (match := re.fullmatch(r'map\s*:\s*([a-z0-9_]+)', line))]
    if len(maps) != 1:
        raise RuntimeError('Console did not report one valid active map')
    header = next((index for index, line in enumerate(lines) if line.startswith('num score ping ')), None)
    if header is None or header + 1 >= len(lines) or not lines[header + 1].startswith('--- '):
        raise RuntimeError('Unrecognized console player header')
    prefix_fields = 4 if 'guid' in lines[header].split() else 5
    players = []
    for line in lines[header + 2:]:
        # SV_Status_f terminates the complete client table with a blank line.
        # Later console traffic (for example getstatus diagnostics) is not a client row.
        if not line or line.lstrip(']').startswith('echo OPENCJ_END_'):
            break
        columns = line.split(maxsplit=prefix_fields)
        if len(columns) != prefix_fields + 1 or not columns[0].isdigit():
            raise RuntimeError('Unrecognized player status; source preserved')
        remainder = columns[-1].rsplit(maxsplit=4)
        if len(remainder) != 5 or not remainder[1].isdigit():
            raise RuntimeError('Incomplete console player status; source preserved')
        players.append(remainder[0].strip())
    return {'map': maps[0], 'players': players}


def source_status(source):
    return parse_console_status(console_output(source['server'], 'status'))


def set_source_map(container, map_name):
    if not re.fullmatch(r'[a-z0-9_]+', map_name):
        raise ValueError('Invalid source map')
    console_output(container, 'map ' + map_name)


def resume_source(bundle, journal):
    """Restore only recorded source state; interrupted rehearsals can call this again."""
    source = journal['source']
    if journal.get('database_frozen'):
        if not inspect_container(source['db'])['State']['Running']:
            run(['docker', 'start', source['db']])
        deadline = time.monotonic() + SOURCE_START_TIMEOUT_SECONDS
        while True:
            try:
                with MySQL(source['db'], source['database']) as db:
                    # Undo only the global values captured before this operation.
                    db.query('SET GLOBAL super_read_only=OFF;')
                    db.query('SET GLOBAL read_only=' + str(journal['read_only']) + ';')
                    db.query('SET GLOBAL super_read_only=' + str(journal['super_read_only']) + ';')
                break
            except RuntimeError:
                if time.monotonic() >= deadline:
                    raise
                time.sleep(2)
        journal['database_frozen'] = False
        save_json(bundle / 'journal.json', journal)
    if journal.get('game_stopped'):
        run(['docker', 'start', source['server']])
        deadline = time.monotonic() + SOURCE_START_TIMEOUT_SECONDS
        requested_map = False
        while True:
            try:
                status = source_status(source)
                if status['map'] == journal['active']['map']:
                    break
                if not requested_map:
                    if status['players']:
                        raise RuntimeError('Players joined before map restoration; source requires operator attention')
                    set_source_map(source['server'], journal['active']['map'])
                    requested_map = True
            except (OSError, RuntimeError):
                if time.monotonic() >= deadline:
                    raise RuntimeError('Source map restoration did not complete; rerun --resume-source')
            time.sleep(2)
        journal['game_stopped'] = False
        save_json(bundle / 'journal.json', journal)


def copy_file(source, target, *, public=False):
    """Publish each copied file atomically; a retry can reuse byte-identical completed files."""
    source = source.resolve()
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.is_file() and target.stat().st_size == source.stat().st_size:
        if sha256_file(target) == sha256_file(source):
            return
    temporary = target.with_name('.' + target.name + '.partial')
    temporary.unlink(missing_ok=True)
    require_migration_space(target.parent, source.stat().st_size)
    with source.open('rb') as incoming, temporary.open('wb') as outgoing:
        shutil.copyfileobj(incoming, outgoing, FILE_CHUNK_BYTES)
    temporary.chmod(0o644 if public else 0o600)
    os.replace(temporary, target)


def copy_assets(source, bundle):
    """Include game libraries, compiled client files and all installed map binaries."""
    game = Path(source['game'])
    mod = Path(source['mod'])
    for name in ('steam_api.so', 'steamclient.so'):
        copy_file(game / name, bundle / 'game' / name, public=True)
    for directory, suffixes in [('main', {'.iwd'}), ('zone', {'.ff'}), ('usermaps', {'.ff', '.iwd'})]:
        (bundle / 'game' / directory).mkdir(parents=True, exist_ok=True)
        for path in sorted((game / directory).rglob('*')):
            if path.is_file() and path.suffix.lower() in suffixes:
                copy_file(path, bundle / 'game' / path.relative_to(game), public=True)
    for path in [mod / 'mod.ff', *sorted(mod.glob('*.iwd'))]:
        copy_file(path, bundle / 'mod' / path.name, public=True)


def copy_runtime(source, bundle):
    """Carry persistent player/editor files; keep old configuration as private reference."""
    runtime = Path(source['runtime'])
    for path in sorted(runtime.rglob('*')):
        if path.is_symlink() or not path.is_file():
            continue
        relative = path.relative_to(runtime)
        # Immutable scripts/assets are supplied by the selected release and asset sets.
        if relative.parts[:3] in (('mods', 'opencj', 'opencj'), ('mods', 'opencj', 'maps')):
            continue
        if path.suffix.lower() in ('.iwd', '.ff', '.so', '.log'):
            continue
        destination = 'source-config' if path.suffix.lower() == '.cfg' else 'runtime'
        copy_file(path, bundle / destination / relative)
    (bundle / 'runtime').mkdir(exist_ok=True)


def table_content_digest(db, table):
    """Return a digest of the table's logical rows, independent of row order and storage layout.

    CHECKSUM TABLE compares stored bytes, so it cannot allow for the FLOAT rounding
    described below, and MySQL documents that its value also depends on the row
    format. Each row is therefore hashed from its JSON value list (NULL stays distinct from
    empty text; blobs have one representation). The row hashes are summed exactly
    as DECIMAL, which counts duplicate rows and needs no primary key.

    FLOAT columns are hashed in the server's text form. mysqldump writes FLOAT values
    with about six significant digits, so a restore can change their last bits; the
    text form is exactly what a dump preserves. Source and target run the same MySQL
    version, so both sides format FLOAT values identically.
    """
    column_rows = db.query(
        'SELECT COLUMN_NAME, DATA_TYPE FROM information_schema.COLUMNS '
        'WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=' + quote_literal(table) + ' '
        'ORDER BY ORDINAL_POSITION;').splitlines()
    if not column_rows:
        raise RuntimeError('Database table has no readable columns: ' + table)
    column_values = []
    for column_row in column_rows:
        column_name, data_type = column_row.split('\t')
        column_value = quote_identifier(column_name)
        if data_type == 'float':
            column_value = 'CAST(' + column_value + ' AS CHAR)'
        column_values.append(column_value)
    row_values = 'JSON_ARRAY(' + ', '.join(column_values) + ')'
    lane_sums = []
    for lane_index in range(DIGEST_LANE_COUNT):
        first_digit = lane_index * DIGEST_LANE_HEX_DIGITS + 1
        lane_value = ('CAST(CONV(SUBSTRING(row_digest, ' + str(first_digit) + ', '
                      + str(DIGEST_LANE_HEX_DIGITS) + '), 16, 10) AS UNSIGNED)')
        lane_sums.append('COALESCE(SUM(' + lane_value + '), 0)')
    totals = db.query(
        'SELECT COUNT(*), ' + ', '.join(lane_sums) + ' '
        'FROM (SELECT SHA2(' + row_values + ', 256) AS row_digest '
        'FROM ' + quote_identifier(table) + ') AS table_rows;',
        timeout=INVENTORY_QUERY_TIMEOUT_SECONDS).split('\t')
    if len(totals) != DIGEST_LANE_COUNT + 1 or not all(value.isdigit() for value in totals):
        raise RuntimeError('Unexpected table digest result for ' + table)
    row_count = int(totals[0])
    lane_text = ':'.join(totals[1:])
    return row_count, hashlib.sha256(lane_text.encode()).hexdigest()


def database_inventory(db):
    """Record row counts and logical content digests while writers are frozen.

    Only digests leave the database, so no player data is printed or stored. The
    session time zone is fixed to UTC while hashing because JSON renders TIMESTAMP
    values in the session zone; the caller's zone is restored afterwards because
    the same session may later apply schema migrations.
    """
    tables = db.query(
        "SELECT TABLE_NAME FROM information_schema.TABLES "
        "WHERE TABLE_SCHEMA=DATABASE() AND TABLE_TYPE='BASE TABLE' ORDER BY TABLE_NAME;").splitlines()
    previous_time_zone = db.query('SELECT @@session.time_zone;')
    db.query("SET time_zone='+00:00';")
    try:
        result = {}
        for table in tables:
            row_count, content_digest = table_content_digest(db, table)
            result[table] = {'rows': row_count, 'sha256': content_digest}
        return result
    finally:
        # A failed query closes the session; there is then no zone left to restore.
        if not db.closed:
            db.query('SET time_zone=' + quote_literal(previous_time_zone) + ';')

def require_no_other_writers(db):
    """Do not freeze another game/admin connection while its owner may still be saving."""
    rows = db.query(
        "SELECT DISTINCT USER FROM information_schema.PROCESSLIST "
        "WHERE ID<>CONNECTION_ID() AND USER NOT IN ('event_scheduler','system user');")
    from runtime_access import quote_literal
    for user in rows.splitlines():
        # This migration supports the project's application accounts at host %.
        # An unknown/root connection is deliberately not treated as a harmless reader.
        if user == 'root':
            raise RuntimeError('Another database administrator is connected; source migration postponed')
        grants = db.query('SHOW GRANTS FOR ' + quote_literal(user) + "@'%';")
        for grant in grants.splitlines():
            privileges, separator, remainder = grant.removeprefix('GRANT ').partition(' ON ')
            allowed = {value.strip() for value in privileges.split(',')} <= {'SELECT', 'USAGE'}
            if not grant.startswith('GRANT ') or not separator or not allowed or 'WITH GRANT OPTION' in remainder:
                raise RuntimeError('Another database writer is connected; stop its game instance before migration')


def dump_database(source, bundle):
    """Use the existing backup selection/options, streaming directly to a private file."""
    temporary = bundle / '.database.sql.partial'
    command = [
        'docker', 'exec', source['db'], 'sh', '-c',
        'MYSQL_PWD="${MYSQL_ROOT_PASSWORD:-$(cat \"$MYSQL_ROOT_PASSWORD_FILE\")}" exec mysqldump -u root '
        '--single-transaction --quick --hex-blob --routines --triggers --events '
        '--no-tablespaces --set-gtid-purged=OFF --column-statistics=0 --databases ' + source['database'],
    ]
    with temporary.open('wb') as output, (bundle / 'export.log').open('ab') as errors:
        result = subprocess.run(command, stdout=output, stderr=errors, timeout=TRANSFER_TIMEOUT_SECONDS)
    if result.returncode:
        raise RuntimeError('Database export failed; source data preserved')
    os.replace(temporary, bundle / 'database.sql')


def bundle_inventory(bundle, *, directories=('game', 'mod', 'runtime', 'source-config'), include_database=True):
    result = {}
    for name in directories:
        directory = bundle / name
        if not directory.exists():
            continue
        for path in sorted(directory.rglob('*')):
            if path.is_file():
                result[path.relative_to(bundle).as_posix()] = {
                    'bytes': path.stat().st_size, 'sha256': sha256_file(path)}
    if include_database:
        sql = bundle / 'database.sql'
        result[sql.name] = {'bytes': sql.stat().st_size, 'sha256': sha256_file(sql)}
    return result


def export_source(source_directory, bundle, *, intent, allowed_player='', prepare_only=False,
                  without_assets=False):
    # Serialize maintenance across destination machines, not just repeated calls
    # using one bundle. Reuse the installed instance's own setup lock.
    with operation_lock(source_directory.resolve() / '.setup.lock'):
        return export_locked(source_directory, bundle, intent=intent, allowed_player=allowed_player,
                             prepare_only=prepare_only, without_assets=without_assets)


def export_locked(source_directory, bundle, *, intent, allowed_player='', prepare_only=False,
                  without_assets=False):
    """Export once; rehearse resumes the source, cutover keeps its writers fenced.

    without_assets leaves game files and maps out: a copy on the same host uses the
    host's shared asset folder instead of a second 16 GiB copy.
    """
    bundle = bundle.resolve()
    if bundle.exists() and not (bundle / 'journal.json').exists() and any(bundle.iterdir()):
        raise ValueError('Bundle directory is not empty; existing files preserved')
    bundle.mkdir(parents=True, mode=0o700, exist_ok=True)
    with operation_lock(bundle / '.export.lock'):
        journal_path = bundle / 'journal.json'
        if journal_path.exists():
            journal = read_json(journal_path)
            if journal['source']['directory'] != str(source_directory.resolve()) or journal['intent'] != intent:
                raise ValueError('Bundle belongs to a different source or migration intent')
        else:
            source = select_source(source_directory)
            journal = {'source': source, 'intent': intent, 'state': 'copying-assets'}
            save_json(journal_path, journal)
        if journal.get('state') == 'cancelled':
            raise RuntimeError('This cutover was cancelled; create a new migration snapshot')
        if (bundle / 'manifest.json').exists():
            if intent == 'rehearsal':
                resume_source(bundle, journal)
            elif journal.get('state') != 'accepted':
                source = journal['source']
                if inspect_container(source['server'])['State']['Running']:
                    raise RuntimeError('Source was restarted after snapshot; create a new migration snapshot')
                if inspect_container(source['db'])['State']['Running']:
                    with MySQL(source['db'], source['database']) as db:
                        if db.query('SELECT @@global.super_read_only;') != '1':
                            raise RuntimeError('Source database fencing was removed; snapshot is no longer a cutover')
                        require_no_other_writers(db)
                    run(['docker', 'stop', '--time', '60', source['db']], timeout=90)
            return read_json(bundle / 'manifest.json')
        source = journal['source']
        # A killed export may have left writers frozen. Restore rehearsal state
        # before capturing a new consistent snapshot; cutover stays fenced.
        if intent == 'rehearsal' and (journal.get('database_frozen') or journal.get('game_stopped')):
            resume_source(bundle, journal)
        asset_files = {}
        if not without_assets:
            copy_assets(source, bundle)
        if prepare_only:
            return {'state': 'assets-ready'}
        if not without_assets:
            # Assets are already a fixed copy. Hash their potentially large inventory
            # before stopping gameplay, leaving only mutable state in the outage window.
            asset_files = bundle_inventory(bundle, directories=('game', 'mod'), include_database=False)
        try:
            if not journal.get('game_stopped'):
                active = source_status(source)
                if any(player != allowed_player for player in active['players']):
                    raise RuntimeError('Other players are connected; source was not stopped')
                journal['active'] = active
                journal['game_stopped'] = True
                save_json(journal_path, journal)
                run(['docker', 'stop', '--time', '60', source['server']], timeout=90)
            with MySQL(source['db'], source['database']) as db:
                require_no_other_writers(db)
                if not journal.get('database_frozen'):
                    values = db.query('SELECT @@global.read_only,@@global.super_read_only;').split('\t')
                    journal['read_only'], journal['super_read_only'] = map(int, values)
                    journal['database_frozen'] = True
                    save_json(journal_path, journal)
                db.query('SET GLOBAL super_read_only=ON;')
                version = db.query('SELECT VERSION();')
                inventory = database_inventory(db)
                storage_bytes = int(db.query(
                    'SELECT COALESCE(SUM(DATA_LENGTH+INDEX_LENGTH),0) FROM information_schema.TABLES '
                    'WHERE TABLE_SCHEMA=DATABASE();'))
                # SQL escaping/hex blobs can expand data; reserve room before starting the dump.
                estimated_dump_bytes = storage_bytes * 3 + 64 * 1024 * 1024
                require_migration_space(bundle, estimated_dump_bytes)
            dump_database(source, bundle)
            for name in ('runtime', 'source-config'):
                directory = bundle / name
                if directory.exists():
                    shutil.rmtree(directory)
            copy_runtime(source, bundle)
            manifest = {
                'format': FORMAT_VERSION, 'database': source['database'], 'mysql_version': version,
                'tables': inventory, 'map': journal['active']['map'],
                'core_revision': source['core_revision'], 'includes_assets': not without_assets,
                'files': asset_files | bundle_inventory(bundle, directories=('runtime', 'source-config')),
            }
            save_json(bundle / 'manifest.json', manifest)
            journal['state'] = 'complete'
            save_json(journal_path, journal)
            if intent == 'cutover':
                run(['docker', 'stop', '--time', '60', source['db']], timeout=90)
            return manifest
        finally:
            if intent == 'rehearsal':
                resume_source(bundle, journal)
