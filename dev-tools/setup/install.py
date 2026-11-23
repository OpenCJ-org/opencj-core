#!/usr/bin/env python3
"""Install or recheck one OpenCJ beta instance. Existing instances are never reset."""

import argparse
from contextlib import contextmanager
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
import time

from assets import prepare_assets
from assets import sha256_file
from configuration import collect_configuration
from configuration import MYSQL_IMAGE
from configuration import RELEASE
from configuration import validate_configuration
from compose_config import compose_document
from compose_config import connection_host
from compose_config import database_network

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'server-db/tools'))
from mysql_session import MySQL
import migrate
import runtime_access

spec = importlib.util.spec_from_file_location('setup_bootstrap', ROOT / 'dev-tools/scripts/bootstrap-db.py')
bootstrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)
DOCKER_TIMEOUT_SECONDS = 180
BUILD_TIMEOUT_SECONDS = 1800


def run(command, *, timeout=DOCKER_TIMEOUT_SECONDS, log=None):
    """Keep command output private; errors name the stage without echoing SQL or secrets."""
    if log:
        with log.open('ab') as output:
            result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, timeout=timeout)
    else:
        result = subprocess.run(command, capture_output=True, timeout=timeout)
    if result.returncode:
        detail = f'; see private log {log}' if log else ''
        raise RuntimeError(f'{command[0]} {command[1]} failed{detail}')
    if not log:
        return result.stdout.decode().strip()
    return ''


def write_private(path, text, *, owner=None):
    """Replace generated metadata atomically without exposing an intermediate public file."""
    descriptor, temporary_name = tempfile.mkstemp(prefix='.' + path.name + '-', dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, 'w') as output:
            output.write(text)
        if owner and os.getuid() == 0:
            os.chown(temporary, *owner)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def write_generated(path, text, *, owner=None):
    """Retry a partial preparation only when its existing generated file still agrees."""
    if path.exists():
        if path.read_text() != text:
            raise RuntimeError(f'{path.name} differs from setup choices; existing file preserved')
        return
    write_private(path, text, owner=owner)


def save_installation(instance, settings):
    write_private(instance / 'installation.json', json.dumps(settings, indent=2) + '\n')


def compose(instance, settings, *arguments, log=None, timeout=DOCKER_TIMEOUT_SECONDS):
    return run(['docker', 'compose', '-p', settings['project'], '-f', str(instance / 'compose.json'),
                *arguments], log=log, timeout=timeout)


def mysql_option(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'


def client_config(settings, *, administrator=False):
    database = settings['database']
    host = connection_host(settings)
    port = 3306 if database.get('transport') == 'ssh' else database['port']
    user = 'root' if administrator else database['user']
    password = settings['root_password'] if administrator else database['password']
    return '\n'.join(['[client]', 'host=' + mysql_option(host), 'port=' + str(port),
                      'user=' + mysql_option(user), 'password=' + mysql_option(password),
                      'connect-timeout=10', 'protocol=TCP', ''])


@contextmanager
def database_client(instance, settings, *, administrator=False):
    """Use the existing bounded SQL transport with credentials supplied as a read-only file."""
    filename = 'admin.cnf' if administrator else 'client.cnf'
    client_name = settings['project'] + '-sql-' + secrets.token_hex(4)
    command = [
        'docker', 'run', '--rm', '--name', client_name, '-i', '--network', database_network(settings),
        '--label', 'org.opencj.setup=' + settings['project'],
        '--mount', f'type=bind,src={instance / "secrets" / filename},dst=/run/client.cnf,readonly',
        MYSQL_IMAGE, 'mysql', '--defaults-file=/run/client.cnf', '--batch', '--raw',
        '--skip-column-names', '--unbuffered', '--binary-as-hex', settings['database']['name'],
    ]
    try:
        with MySQL(None, settings['database']['name'], command=command) as database:
            yield database
    finally:
        remaining = run(['docker', 'ps', '-aq', '--filter', 'name=^/' + client_name + '$'])
        if remaining:
            run(['docker', 'rm', '-f', client_name], timeout=30)


def check_database(db):
    version = db.query('SELECT VERSION();')
    if not version.startswith('8.0.') or 'MariaDB' in version:
        raise RuntimeError('This release has been validated with MySQL 8.0; database was preserved')
    return bootstrap.check(db)


def check_runtime_grants(db):
    """Require the existing gameplay policy; never accept roles or broader privileges."""
    database = db.query('SELECT DATABASE();')
    quote = runtime_access.quote_identifier
    schema = quote(database.replace('_', '\\_'))
    required = {'*.*': {'USAGE'}, schema + '.*': {'SELECT'}}
    for table in runtime_access.WRITABLE_TABLES | runtime_access.INSERT_ONLY_TABLES:
        scope = quote(database) + '.' + quote(table)
        required[scope] = {'INSERT'}
        if table in runtime_access.WRITABLE_TABLES:
            required[scope].add('UPDATE')
    for table in runtime_access.DELETABLE_TABLES:
        scope = quote(database) + '.' + quote(table)
        required.setdefault(scope, set()).add('DELETE')
    routines = db.query("""
        SELECT ROUTINE_NAME, ROUTINE_TYPE
        FROM information_schema.ROUTINES
        WHERE ROUTINE_SCHEMA = DATABASE();
        """)
    for row in routines.splitlines():
        name, kind = row.split('\t')
        required[kind + ' ' + quote(database) + '.' + quote(name.lower())] = {'EXECUTE'}

    actual = {}
    for grant in db.query('SHOW GRANTS FOR CURRENT_USER;').splitlines():
        privileges, on_separator, target = grant.removeprefix('GRANT ').partition(' ON ')
        scope, to_separator, principal = target.partition(' TO ')
        # MySQL SHOW GRANTS canonicalizes routine names; routine lookup is case-insensitive.
        if scope.startswith(('PROCEDURE ', 'FUNCTION ')):
            prefix, separator, name = scope.rpartition('.')
            scope = prefix + separator + name.lower()
        granted = {privilege.strip() for privilege in privileges.split(',')}
        if (not grant.startswith('GRANT ') or not on_separator or not to_separator
                or 'WITH GRANT OPTION' in principal or scope not in required
                or not granted <= required[scope]):
            raise RuntimeError('Gameplay account has privileges outside the reviewed runtime policy')
        actual.setdefault(scope, set()).update(granted)
    if actual != required:
        raise RuntimeError('Gameplay account is missing required runtime permissions; ask its owner to apply the policy')


def wait_for_database(instance, settings):
    deadline = time.monotonic() + 120
    while True:
        try:
            with database_client(instance, settings) as db:
                db.query('SELECT 1;', timeout=15)
            return
        except (RuntimeError, TimeoutError):
            if time.monotonic() >= deadline:
                raise RuntimeError('Database connection failed; credentials and existing data were preserved') from None
            time.sleep(2)


def initialize_database(instance, settings):
    """Initialize only an owned empty schema; joining never runs migrations or grants."""
    database = settings['database']
    wait_for_database(instance, settings)
    if database['mode'] == 'new':
        with database_client(instance, settings, administrator=True) as db:
            migrate.lock_database(db, database['name'])
            objects = int(db.query(
                'SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE();'))
            if objects == 0:
                bootstrap.bootstrap(db, database['name'], database['user'])
            else:
                check_database(db)
            # A completed ledger can precede a lost grant reply. Only this owned
            # database may reapply the existing reviewed policy on a setup retry.
            runtime_access.apply_policy(db, database['name'], account=database['user'])
    with database_client(instance, settings) as db:
        migration_count = check_database(db)
        check_runtime_grants(db)
    settings['migrations'] = migration_count


def write_instance_files(instance, settings):
    """Create generated launch files once; the installation record owns subsequent retries."""
    runtime = instance / 'runtime'
    runtime.mkdir(exist_ok=True)
    owner = (settings['uid'], settings['gid'])
    if os.getuid() == 0:
        os.chown(runtime, *owner)
    (instance / 'secrets').mkdir(mode=0o700, exist_ok=True)
    database = settings['database']
    write_generated(instance / 'secrets/client.cnf', client_config(settings))
    if database['mode'] == 'new':
        write_generated(instance / 'secrets/admin.cnf', client_config(settings, administrator=True))
        write_generated(instance / 'secrets/root-password', settings['root_password'])
        write_generated(instance / 'secrets/runtime-password', database['password'])
    if database.get('transport') == 'ssh':
        # OpenSSH needs a passwd entry even when the host's numeric UID is not
        # present in the immutable image. This file contains no authentication data.
        passwd = f"opencj:x:{settings['uid']}:{settings['gid']}::/tmp:/usr/sbin/nologin\n"
        write_generated(instance / 'secrets/ssh-passwd', passwd, owner=owner)
        for source_key, target in [('key', 'ssh-key'), ('known_hosts', 'known_hosts')]:
            contents = Path(database['ssh'][source_key]).read_text()
            write_generated(instance / 'secrets' / target, contents, owner=owner)
    port = 3306 if database.get('transport') == 'ssh' else database['port']
    cvars = {'sv_hostname': settings['hostname'], 'sv_punkbuster': '0', 'sv_allowDownload': '1',
             'sv_floodProtect': '4', 'g_password': settings['join_password'],
             'rcon_password': settings['rcon_password'], 'db_host': connection_host(settings),
             'db_port': str(port), 'db_user': database['user'], 'db_pass': database['password'],
             'db_base': database['name'][:-1], 'opencj_checkpoint_editor': '0'}
    write_generated(instance / 'server.cfg', ''.join(f'set {key} "{value}"\n' for key, value in cvars.items())
                  + f'sets opencj_version "{RELEASE}"\n', owner=owner)
    runtime_settings = {key: settings[key] for key in ('public', 'slots', 'map')}
    write_generated(instance / 'runtime.json', json.dumps(runtime_settings) + '\n', owner=owner)
    write_generated(instance / 'compose.json', json.dumps(compose_document(settings, instance), indent=2) + '\n')
    write_generated(instance / 'join-password', settings['join_password'] + '\n')
    write_generated(instance / 'rcon-password', settings['rcon_password'] + '\n')
    settings['managed_hashes'] = {name: sha256_file(instance / name)
                                  for name in ('server.cfg', 'runtime.json', 'compose.json')}


def verify_managed_files(instance, settings):
    for name, expected in settings['managed_hashes'].items():
        if not (instance / name).is_file() or sha256_file(instance / name) != expected:
            raise RuntimeError(f'{name} has operator changes; preserved without restarting or rewriting it')


def validate_source():
    if (ROOT / 'VERSION').read_text().strip() != RELEASE:
        raise RuntimeError('Installer and source release versions disagree')
    source_revision = run(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'])
    pin = run(['git', '-C', str(ROOT), 'ls-tree', 'HEAD', 'cod4x-server']).split()[2]
    if not (ROOT / 'cod4x-server/.git').exists():
        run(['git', '-C', str(ROOT), 'submodule', 'update', '--init', '--', 'cod4x-server'], timeout=600)
    engine_revision = run(['git', '-C', str(ROOT / 'cod4x-server'), 'rev-parse', 'HEAD'])
    if engine_revision != pin:
        raise RuntimeError('Engine differs from the core pin; local work was preserved')
    if run(['git', '-C', str(ROOT / 'cod4x-server'), 'diff', 'HEAD', '--']):
        raise RuntimeError('Engine has tracked changes; commit the intended engine revision first')
    return source_revision, engine_revision


def build_release(instance, settings):
    """Build inside Docker; no compiler writes to the canonical or running engine tree."""
    source_revision, engine_revision = validate_source()
    log = instance / 'build.log'
    builder = 'opencj-builder:' + RELEASE
    run(['docker', 'build', '-t', builder, '-f', str(ROOT / 'dev-tools/Dockerfile'),
         str(ROOT / 'dev-tools')], log=log, timeout=BUILD_TIMEOUT_SECONDS)
    run(['docker', 'build', '-t', settings['image'],
         '--build-arg', 'BUILDER_IMAGE=' + builder,
         '--build-arg', 'SOURCE_REVISION=' + source_revision,
         '--build-arg', 'ENGINE_REVISION=' + engine_revision,
         '-f', str(ROOT / 'dev-tools/setup/Dockerfile'), str(ROOT)], log=log, timeout=BUILD_TIMEOUT_SECONDS)
    settings['source_revision'] = source_revision
    settings['engine_revision'] = engine_revision
    settings['image_id'] = run(['docker', 'image', 'inspect', settings['image'], '--format', '{{.Id}}'])


def ensure_owned_volume(settings):
    """Never adopt a pre-existing unlabelled volume, including one from another installation."""
    volume = settings['volume']
    existing = run(['docker', 'volume', 'ls', '--filter', 'name=^' + volume + '$', '--format', '{{.Name}}'])
    if existing:
        metadata = json.loads(run(['docker', 'volume', 'inspect', volume]))[0]
        if (metadata.get('Labels') or {}).get('org.opencj.instance') != settings['project']:
            raise RuntimeError('Database volume belongs to another installation; preserved')
    else:
        run(['docker', 'volume', 'create', '--label', 'org.opencj.instance=' + settings['project'], volume])


def website_command(settings, *arguments):
    path = Path(settings['website_compose'])
    return ['docker', 'compose', '-p', settings['project'] + '-web', '--project-directory', str(path.parent),
            '-f', str(path), *arguments]


def verify_website(settings):
    """Require Claude's supplied project; never substitute an unrelated or placeholder website."""
    if not settings.get('website_compose'):
        return
    definition = json.loads(run(website_command(settings, 'config', '--format', 'json')))
    for service in definition['services'].values():
        if service.get('container_name'):
            raise ValueError('Website Compose must use project-scoped names, not container_name')
    for volume in definition.get('volumes', {}).values():
        if volume.get('external'):
            raise ValueError('Website external volumes require explicit separate provisioning')
        if not volume.get('name', '').startswith(settings['project'] + '-web_'):
            raise ValueError('Website volume names must be scoped to its Compose project')
    settings['website_hash'] = sha256_file(Path(settings['website_compose']))


def server_is_running(instance, settings):
    return bool(compose(instance, settings, 'ps', '--status', 'running', '--quiet', 'server'))


def check_ready(instance, settings):
    verify_managed_files(instance, settings)
    with database_client(instance, settings) as db:
        check_database(db)
        check_runtime_grants(db)
    if not server_is_running(instance, settings):
        raise RuntimeError('Installed server is stopped; setup preserved it. Use the documented start procedure')
    containers = json.loads(run(['docker', 'inspect', compose(instance, settings, 'ps', '--quiet', 'server')]))
    if containers[0]['Image'] != settings['image_id']:
        raise RuntimeError('Running image differs from the recorded release')
    if containers[0]['State'].get('Health', {}).get('Status') != 'healthy':
        raise RuntimeError('Server has not passed its game-protocol healthcheck')
    if settings.get('website_compose'):
        if sha256_file(Path(settings['website_compose'])) != settings['website_hash']:
            raise RuntimeError('Website definition changed; existing project preserved')
    print(f"Verified {settings['name']} ({RELEASE}); configuration, data and running processes preserved.")


def install(instance, settings):
    """Resume owned installation stages; never restart an already accepted running instance."""
    if settings['state'] == 'ready':
        check_ready(instance, settings)
        return
    if settings['state'] == 'configured':
        prepare_instance(instance, settings)
    verify_managed_files(instance, settings)
    verify_website(settings)
    if not settings.get('image_id'):
        print('Building the pinned engine and release image...', flush=True)
        build_release(instance, settings)
        save_installation(instance, settings)
    if settings['database']['mode'] == 'new':
        ensure_owned_volume(settings)
        compose(instance, settings, 'up', '-d', '--wait', '--wait-timeout', '180', 'db', log=instance / 'setup.log', timeout=240)
    elif settings['database'].get('transport') == 'ssh':
        compose(instance, settings, 'up', '-d', 'db-tunnel', log=instance / 'setup.log')
    elif not settings['database'].get('network'):
        # Compose creates this project's network without starting gameplay.
        compose(instance, settings, 'create', 'server', log=instance / 'setup.log')
    print('Checking database schema and gameplay permissions...', flush=True)
    initialize_database(instance, settings)
    settings['state'] = 'database-ready'
    save_installation(instance, settings)
    compose(instance, settings, 'up', '-d', '--wait', '--wait-timeout', '180', 'server', log=instance / 'setup.log', timeout=240)
    if settings.get('website_compose'):
        run(website_command(settings, 'up', '-d', '--wait', '--wait-timeout', '180'), log=instance / 'website.log', timeout=240)
    settings['state'] = 'ready'
    save_installation(instance, settings)
    check_ready(instance, settings)
    print(f'Private connection details: {instance / "join-password"}')
    print(f'Administration secret: {instance / "rcon-password"}')
    print('Setup is complete. Public beta release still requires the documented gameplay/readiness checks.')


def initialize_instance(instance, supplied):
    if any(path.name != '.setup.lock' for path in instance.iterdir()):
        raise ValueError('Installation directory is not empty; existing files were preserved')
    settings = validate_configuration(supplied)
    verify_website(settings)
    settings['instance_dir'] = str(instance)
    settings['state'] = 'configured'
    settings['image'] = settings['project'] + ':' + RELEASE
    if settings['database']['mode'] == 'new':
        settings['root_password'] = secrets.token_hex(32)
    save_installation(instance, settings)
    return settings


def prepare_instance(instance, settings):
    # Keep the original choices and generated identities if a download fails.
    # Only owned temporary extraction files are discarded; a retry can resume.
    for kind in ('game', 'mod'):
        settings[f'{kind}_dir'] = str(prepare_assets(settings[f'{kind}_assets'], kind, instance,
                                                   settings.get(f'{kind}_sha256', '')))
    write_instance_files(instance, settings)
    settings['state'] = 'prepared'
    save_installation(instance, settings)


def backup_instance(instance, settings):
    """Reuse the verified backup/restore tool on the database owned by this installation."""
    if settings['database']['mode'] != 'new':
        raise ValueError('Back up a shared database from its owning installation')
    verify_managed_files(instance, settings)
    container = compose(instance, settings, 'ps', '--status', 'running', '--quiet', 'db')
    if not container or '\n' in container:
        raise RuntimeError('Expected one running database owned by this installation')
    command = [sys.executable, '-B', str(ROOT / 'dev-tools/scripts/backup.py'),
               '--container', container, '--database', settings['database']['name'],
               '--output-dir', str(instance / 'backups')]
    for name in ('installation.json', 'compose.json', 'server.cfg', 'runtime.json', 'secrets', 'runtime'):
        command.extend(['--source', str(instance / name)])
    run(command, timeout=1800, log=instance / 'backup.log')
    print(f'Backup and isolated restore check completed: {instance / "backups"}')


def load_installation(instance):
    """Bind operational identities to their original directory before any Docker operation."""
    settings = json.loads((instance / 'installation.json').read_text())
    if settings.get('instance_dir') != str(instance):
        raise ValueError('Installation record belongs to another directory; use the original installation')
    if settings.get('release') != RELEASE:
        raise ValueError('Different installed release; follow the upgrade procedure')
    return settings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--instance-dir', type=Path, help='Separate installation directory, e.g. /srv/opencj/main')
    parser.add_argument('--config', type=Path, help='Private JSON answers for unattended installation')
    actions = parser.add_mutually_exclusive_group()
    actions.add_argument('--check', action='store_true', help='Check an existing installation without starting services')
    actions.add_argument('--backup', action='store_true', help='Back up the owned database/configuration and verify a disposable restore')
    args = parser.parse_args()
    os.umask(0o077)
    if args.instance_dir is None:
        if args.config or args.check or args.backup:
            parser.error('--instance-dir is required with --config, --check or --backup')
        args.instance_dir = Path(input('Installation directory [/srv/opencj/main]: ').strip() or '/srv/opencj/main')
    instance = args.instance_dir.expanduser().resolve()
    settings = None
    try:
        if (instance / 'installation.json').exists():
            settings = load_installation(instance)
        run(['docker', 'info', '--format', '{{.ServerVersion}}'])
        run(['docker', 'compose', 'version'])
        if instance.exists() and any(instance.iterdir()) and not (instance / 'installation.json').is_file():
            raise ValueError('Installation directory is not empty; existing files were preserved')
        instance.mkdir(parents=True, mode=0o700, exist_ok=True)
        with (instance / '.setup.lock').open('a') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise RuntimeError('Another setup operation owns this installation') from None
            record = instance / 'installation.json'
            if record.exists():
                if args.config:
                    raise ValueError('Existing installation preserved; do not supply new answers on a repeat run')
                settings = load_installation(instance)
            else:
                if args.check or args.backup:
                    raise ValueError('No installation record exists')
                supplied = json.loads(args.config.read_text()) if args.config else collect_configuration(instance)
                settings = initialize_instance(instance, supplied)
            if args.check:
                check_ready(instance, settings)
            elif args.backup:
                backup_instance(instance, settings)
            else:
                install(instance, settings)
    except (ValueError, RuntimeError, OSError, subprocess.TimeoutExpired, KeyError) as error:
        # Database exceptions can contain SQL. Keep the diagnostic private and
        # give operators a bounded recovery instruction rather than printing it.
        if settings and settings.get('instance_dir') == str(instance):
            write_private(instance / 'failure.txt', str(error) + '\n')
            print(f'Setup stopped. Existing data was preserved. Inspect {instance / "failure.txt"}.', file=sys.stderr)
        else:
            # Preflight may have created only our lock. Never write diagnostics
            # into an unrelated nonempty directory selected by mistake.
            if instance.is_dir() and {path.name for path in instance.iterdir()} == {'.setup.lock'}:
                (instance / '.setup.lock').unlink()
            print('Setup refused before initialization: ' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
