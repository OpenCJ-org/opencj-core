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
import time

from operations import run, write_private
from accounts import provision_owned_account, provision_game_account, GAME_CONNECTION_LIMIT
import linux_accounts
import database_owner
import migration
import website as managed_website
from maintenance import configure_instance_jobs, prepare_offsite
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
spec = importlib.util.spec_from_file_location('geoip_provisioning', ROOT / 'server-db/tools/geoip/provision.py')
geoip_provisioning = importlib.util.module_from_spec(spec)
spec.loader.exec_module(geoip_provisioning)
DOCKER_TIMEOUT_SECONDS = 180
BUILD_TIMEOUT_SECONDS = 1800
# Time the game server and database get to shut down cleanly before Docker kills them.
STOP_GRACE_SECONDS = 30


def write_generated(path, text, *, owner=None, replace=False):
    """Retry a partial preparation only when its existing generated file still agrees.

    replace=True is for an operator's deliberate settings change (opencj configure),
    after verify_managed_files has confirmed nobody edited the generated files by hand.
    """
    if path.exists() and not replace:
        if path.read_text() != text:
            raise RuntimeError(f'{path.name} differs from setup choices; existing file preserved')
        return
    write_private(path, text, owner=owner)


def download_cvars(downloads):
    """Server settings for the chosen map-download mode (see configuration.collect_downloads)."""
    if downloads['mode'] == 'website':
        return {'sv_allowDownload': '1', 'sv_wwwDownload': '1', 'sv_wwwBaseURL': downloads['base_url'],
                'sv_wwwDlDisconnected': '0'}
    if downloads['mode'] == 'in-game':
        return {'sv_allowDownload': '1', 'sv_wwwDownload': '0', 'sv_wwwBaseURL': ''}
    return {'sv_allowDownload': '0', 'sv_wwwDownload': '0', 'sv_wwwBaseURL': ''}


def write_discord_files(instance, settings, *, replace):
    """Bridge configuration (secret) and the socket folder shared by the game and the bridge."""
    discord = settings['discord']
    identity = settings['linux_accounts']['discord']
    owner = (identity['uid'], identity['gid'])
    sockets = instance / 'sockets'
    sockets.mkdir(mode=0o770, exist_ok=True)
    # The bridge creates the socket; the game joins the bridge's group to connect.
    os.chown(sockets, *owner)
    sockets.chmod(0o770)
    directory = instance / 'secrets/discord'
    directory.mkdir(mode=0o700, exist_ok=True)
    os.chown(directory, *owner)
    # The bridge keeps everything after '=' including a line break, so the token is
    # written last without one; the numeric IDs tolerate a trailing line break.
    contents = ('guildid=' + discord['guild_id'] + '\nchannelid=' + discord['channel_id']
                + '\ntoken=' + discord['token'])
    write_generated(directory / 'config_cod4', contents, owner=owner, replace=replace)


def save_installation(instance, settings):
    write_private(instance / 'installation.json', json.dumps(settings, indent=2) + '\n')


def compose(instance, settings, *arguments, log=None, timeout=DOCKER_TIMEOUT_SECONDS):
    return run(['docker', 'compose', '-p', settings['project'], '-f', str(instance / 'compose.json'),
                *arguments], log=log, timeout=timeout)


def mysql_option(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'


def client_config(settings, *, administrator=False, website=False):
    database = settings['database']
    host = connection_host(settings)
    port = 3306 if database.get('transport') == 'ssh' else database['port']
    user = 'root' if administrator else database['user']
    password = settings['root_password'] if administrator else database['password']
    if website:
        user = settings['website']['user']
        password = settings['website']['password']
    # mysqldump (scheduled backups) also reads [client] but rejects connect-timeout,
    # so that option belongs to the mysql client's own group.
    return '\n'.join(['[client]', 'host=' + mysql_option(host), 'port=' + str(port),
                      'user=' + mysql_option(user), 'password=' + mysql_option(password),
                      'protocol=TCP', '[mysql]', 'connect-timeout=10', ''])


@contextmanager
def database_client(instance, settings, *, administrator=False, website=False):
    """Use the existing bounded SQL transport with credentials supplied as a read-only file."""
    filename = 'admin.cnf' if administrator else 'client.cnf'
    if website:
        filename = 'website.cnf'
    client_name = settings['project'] + '-sql-' + secrets.token_hex(4)
    command = [
        'docker', 'run', '--rm', '--log-driver', 'none', '--name', client_name, '-i', '--network', database_network(settings),
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
            with database_client(instance, settings, administrator=settings['database']['mode'] == 'new') as db:
                db.query('SELECT 1;', timeout=15)
            return
        except (RuntimeError, TimeoutError):
            if time.monotonic() >= deadline:
                raise RuntimeError('Database connection failed; credentials and existing data were preserved') from None
            time.sleep(2)


def initialize_database(instance, settings):
    """Initialize/restore only owned storage; joining an external database stays read-only."""
    database = settings['database']
    if not database.get('owner_instance'):
        wait_for_database(instance, settings)
    if database['mode'] == 'new':
        with database_client(instance, settings, administrator=True) as db:
            migrate.lock_database(db, database['name'])
            provision_owned_account(db, database['user'], database['password'], settings['project'],
                                    connection_limit=GAME_CONNECTION_LIMIT)
            if settings.get('migration'):
                container = compose(instance, settings, 'ps', '--quiet', 'db')
                migration.restore_database(instance, settings, db, container)
                migrate.apply_migrations(db, migrate.load_migrations())
            else:
                objects = int(db.query(
                    'SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE();'))
                if objects == 0:
                    bootstrap.bootstrap(db, database['name'], database['user'])
                else:
                    check_database(db)
            provision_game_account(db, settings)
            if settings.get('website'):
                managed_website.provision(db, settings)
        if settings['geoip']['enabled']:
            provision_geoip(instance, settings)
    elif database.get('owner_instance'):
        owner = Path(database['owner_instance'])
        previous = load_installation(owner)
        with database_client(owner, previous, administrator=True) as db:
            check_database(db)
            provision_game_account(db, settings)
            if settings.get('website'):
                managed_website.provision(db, settings)
    with database_client(instance, settings) as db:
        settings['migrations'] = check_database(db)
        check_runtime_grants(db)
    if settings.get('website'):
        with database_client(instance, settings, website=True) as db:
            managed_website.check_grants(db, settings)


def provision_geoip(instance, settings):
    """An updater account limited to the GeoIP tables, via the maintained provisioning helper."""
    container = compose(instance, settings, 'ps', '--quiet', 'db')
    secret = instance / 'secrets/geoip-password'
    geoip_provisioning.provision(container, settings['database']['name'], secret,
                                 account=settings['geoip']['user'])
    identity = settings['linux_accounts']['geoip']
    os.chown(secret, identity['uid'], identity['gid'])


def write_instance_files(instance, settings, *, replace=False):
    """Create generated launch files once; the installation record owns subsequent retries.

    replace=True rewrites the files that follow from operator choices (opencj
    configure and upgrade); generated credentials never change.
    """
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
        database_identity = settings.get('linux_accounts', {}).get('database')
        database_owner = None
        if database_identity:
            database_owner = (database_identity['uid'], database_identity['gid'])
        write_generated(instance / 'secrets/root-password', settings['root_password'], owner=database_owner)
        write_generated(instance / 'secrets/runtime-password', database['password'], owner=database_owner)
    if database.get('transport') == 'ssh':
        # OpenSSH needs a passwd entry even when the host's numeric UID is not
        # present in the immutable image. This file contains no authentication data.
        identity = settings['linux_accounts']['tunnel']
        tunnel_owner = (identity['uid'], identity['gid'])
        passwd = f"opencj:x:{identity['uid']}:{identity['gid']}::/tmp:/usr/sbin/nologin\n"
        write_generated(instance / 'secrets/ssh-passwd', passwd, owner=tunnel_owner)
        for source_key, target in [('key', 'ssh-key'), ('known_hosts', 'known_hosts')]:
            contents = Path(database['ssh'][source_key]).read_text()
            write_generated(instance / 'secrets' / target, contents, owner=tunnel_owner)
    port = 3306 if database.get('transport') == 'ssh' else database['port']
    cvars = {'sv_hostname': settings['hostname'], 'sv_punkbuster': '0',
             'sv_floodProtect': '4', 'g_password': settings['join_password'],
             'rcon_password': settings['rcon_password'], 'db_host': connection_host(settings),
             'db_port': str(port), 'db_user': database['user'], 'db_pass': database['password'],
             'db_base': database['name'][:-1], 'opencj_checkpoint_editor': '0'}
    cvars.update(download_cvars(settings['downloads']))
    if settings['discord']['enabled']:
        write_discord_files(instance, settings, replace=replace)
    write_generated(instance / 'server.cfg', ''.join(f'set {key} "{value}"\n' for key, value in cvars.items())
                    + f'sets opencj_version "{settings["release"]}"\n', owner=owner, replace=replace)
    runtime_settings = {key: settings[key] for key in ('public', 'slots', 'map')}
    write_generated(instance / 'runtime.json', json.dumps(runtime_settings) + '\n', owner=owner, replace=replace)
    write_generated(instance / 'compose.json', json.dumps(compose_document(settings, instance), indent=2) + '\n',
                    replace=replace)
    write_generated(instance / 'join-password', settings['join_password'] + '\n', replace=replace)
    write_generated(instance / 'rcon-password', settings['rcon_password'] + '\n', replace=replace)
    if settings.get('website'):
        write_generated(instance / 'secrets/website.cnf', client_config(settings, website=True))
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
        command = ['git', '-C', str(ROOT), 'submodule', 'update', '--init', '--', 'cod4x-server']
        # A sudo invocation must not leave root-owned Git metadata in the administrator's clone.
        caller_uid = os.environ.get('SUDO_UID', '')
        if os.geteuid() == 0 and caller_uid.isdigit() and ROOT.stat().st_uid == int(caller_uid):
            import pwd
            caller = pwd.getpwuid(int(caller_uid)).pw_name
            command = ['runuser', '-u', caller, '--', *command]
        run(command, timeout=600)
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
    build_optional_images(instance, settings)
    settings['source_revision'] = source_revision
    settings['engine_revision'] = engine_revision
    settings['image_id'] = run(['docker', 'image', 'inspect', settings['image'], '--format', '{{.Id}}'])


def build_optional_images(instance, settings):
    """Images for the Discord bridge and GeoIP updater, built from this release's own sources."""
    log = instance / 'build.log'
    settings['discord_image'] = settings['project'] + '-discord:' + settings['release']
    settings['geoip_image'] = settings['project'] + '-geoip:' + settings['release']
    if settings['discord']['enabled']:
        run(['docker', 'build', '-t', settings['discord_image'],
             '-f', str(ROOT / 'dev-tools/setup/Dockerfile.discord'), str(ROOT / 'discord-integration')],
            log=log, timeout=BUILD_TIMEOUT_SECONDS)
    if settings['geoip']['enabled']:
        run(['docker', 'build', '-t', settings['geoip_image'], str(ROOT / 'server-db/tools/geoip')],
            log=log, timeout=BUILD_TIMEOUT_SECONDS)


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
    identity = settings.get('linux_accounts', {}).get('database')
    if identity:
        # Creation and chown are separate Docker operations. Retry an interrupted
        # empty-volume setup, but never adopt a populated directory with another owner.
        owner = str(identity['uid']) + ':' + str(identity['gid'])
        initialize = ('expected="' + owner + '"\n'
                      'current="$(stat -c %u:%g /var/lib/mysql)"\n'
                      'if [ "$current" != "$expected" ]; then\n'
                      '    if [ -n "$(ls -A /var/lib/mysql)" ]; then\n'
                      '        exit 1\n'
                      '    fi\n'
                      '    chown "$expected" /var/lib/mysql\n'
                      'fi\nchmod 0700 /var/lib/mysql\n')
        run(['docker', 'run', '--rm', '--network', 'none', '--user', '0:0',
             '--cap-drop', 'ALL', '--cap-add', 'CHOWN', '--cap-add', 'DAC_OVERRIDE', '--cap-add', 'FOWNER',
             '--mount', 'type=volume,src=' + volume + ',dst=/var/lib/mysql,volume-nocopy',
             '--entrypoint', 'sh', MYSQL_IMAGE, '-c', initialize])


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


def optional_services(settings):
    services = []
    if settings['discord']['enabled']:
        services.append('discord')
    if settings['geoip']['enabled']:
        services.append('geoip')
    return services


def start_optional_services(instance, settings):
    """Start the Discord bridge and GeoIP updater without waiting for them.

    A wrong Discord token or a provider outage makes these restart in a loop; that
    must never block or fail the game server's installation or a settings change.
    """
    services = optional_services(settings)
    if services:
        compose(instance, settings, 'up', '-d', '--no-deps', *services, log=instance / 'setup.log', timeout=240)


def server_is_running(instance, settings):
    return bool(compose(instance, settings, 'ps', '--status', 'running', '--quiet', 'server'))


def switched_off(instance, settings):
    """True for an on-demand server that was stopped on purpose (sudo opencj stop NAME).

    Docker restarts a crashed game server itself (restart: unless-stopped), so an
    on-demand server that is neither running nor restarting was stopped deliberately.
    """
    if not settings.get('on_demand'):
        return False
    return not compose(instance, settings, 'ps', '--all', '--status', 'running', '--status', 'restarting',
                       '--quiet', 'server')


def stop_services(instance, settings):
    """Stop every container of this server, its own database included; data volumes stay."""
    compose(instance, settings, 'stop', '--timeout', str(STOP_GRACE_SECONDS), log=instance / 'setup.log',
            timeout=DOCKER_TIMEOUT_SECONDS)


def check_ready(instance, settings):
    linux_accounts.verify_accounts(settings)
    if settings.get('website'):
        managed_website.check(instance, settings)
        with database_client(instance, settings, website=True) as db:
            managed_website.check_grants(db, settings)
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
    (instance / 'failure.txt').unlink(missing_ok=True)
    print(f"Verified {settings['name']} ({RELEASE}); configuration, data and running processes preserved.")


def ensure_database_image(instance):
    """Pull the pinned SQL runtime/client before any source maintenance window."""
    available = subprocess.run(['docker', 'image', 'inspect', MYSQL_IMAGE, '--format', '{{.Id}}'],
                               capture_output=True, timeout=DOCKER_TIMEOUT_SECONDS)
    if available.returncode:
        run(['docker', 'pull', MYSQL_IMAGE], log=instance / 'build.log', timeout=BUILD_TIMEOUT_SECONDS)


def install(instance, settings):
    """Resume owned installation stages; never restart an already accepted running instance."""
    if settings['state'] == 'ready':
        migration.source_control(instance, settings, 'accept-cutover')
        if switched_off(instance, settings):
            # Checking it would need its database; starting it is the operator's choice.
            verify_managed_files(instance, settings)
            print(f"{settings['name']} is off (on demand); start it with: sudo opencj start {settings['name']}")
        else:
            check_ready(instance, settings)
        configure_instance_jobs(instance, settings)
        return
    ensure_database_image(instance)
    if settings['state'] == 'configured':
        linux_accounts.ensure_accounts(settings)
        save_installation(instance, settings)
        # Build before source maintenance so compilation cannot extend the outage.
        if not settings.get('image_id'):
            build_release(instance, settings)
            save_installation(instance, settings)
        prepare_instance(instance, settings)
    verify_managed_files(instance, settings)
    verify_website(settings)
    if not settings.get('image_id'):
        print('Building the pinned engine and release image...', flush=True)
        build_release(instance, settings)
        save_installation(instance, settings)
    if settings['database']['mode'] == 'new':
        if settings.get('migration'):
            migration.reset_incomplete_restore(instance, settings)
        ensure_owned_volume(settings)
        compose(instance, settings, 'up', '-d', '--wait', '--wait-timeout', '180', 'db', log=instance / 'setup.log', timeout=240)
    elif settings['database'].get('transport') == 'ssh':
        compose(instance, settings, 'up', '-d', 'db-tunnel', log=instance / 'setup.log')
    elif not settings['database'].get('network'):
        # Compose creates this project's network without starting gameplay.
        compose(instance, settings, 'create', 'server', log=instance / 'setup.log')
    print('Checking database schema and gameplay permissions...', flush=True)
    if settings['state'] != 'database-ready':
        initialize_database(instance, settings)
        settings['state'] = 'database-ready'
        save_installation(instance, settings)
    else:
        # Gameplay may already have started before a later website/acceptance
        # failure. A retry must not revoke/reapply that running game's grants.
        wait_for_database(instance, settings)
        with database_client(instance, settings) as db:
            check_database(db)
            check_runtime_grants(db)
    migration.source_control(instance, settings, 'check-fenced')
    # Transfer write ownership before gameplay can create even its first map-play row.
    # A later startup failure must not permit automatic revival of the old writers.
    migration.source_control(instance, settings, 'accept-cutover')
    compose(instance, settings, 'up', '-d', '--wait', '--wait-timeout', '180', 'server', log=instance / 'setup.log', timeout=240)
    start_optional_services(instance, settings)
    if settings.get('website_compose'):
        run(website_command(settings, 'up', '-d', '--wait', '--wait-timeout', '180'), log=instance / 'website.log', timeout=240)
    if settings.get('website'):
        managed_website.start(instance, settings)
    settings['state'] = 'ready'
    save_installation(instance, settings)
    check_ready(instance, settings)
    configure_instance_jobs(instance, settings)
    if settings.get('on_demand'):
        # Checked while running above; it stays off until it is needed.
        stop_services(instance, settings)
        print(f"{settings['name']} is installed and off (on demand). Start it with: "
              f"sudo opencj start {settings['name']}")
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
    database_owner.prepare_client(instance, settings)
    if settings.get('migration'):
        migration.prepare_bundle(instance, settings)
        save_installation(instance, settings)
    else:
        for kind in ('game', 'mod'):
            settings[kind + '_dir'] = str(prepare_assets(
                settings[kind + '_assets'], kind, instance, settings.get(kind + '_sha256', '')))
    managed_website.prepare(instance, settings)
    write_instance_files(instance, settings)
    prepare_offsite(instance, settings)
    if settings.get('migration'):
        migration.restore_runtime(instance, settings)

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
    if settings.get('website'):
        command.extend(['--source', str(instance / 'website')])
    run(command, timeout=1800, log=instance / 'backup.log')
    print(f'Backup and isolated restore check completed: {instance / "backups"}')


def load_installation(instance, *, allow_other_release=False):
    """Bind operational identities to their original directory before any Docker operation.

    allow_other_release is for the upgrade command and for maintenance jobs, which
    must keep working on installations that have not been upgraded yet.
    """
    settings = json.loads((instance / 'installation.json').read_text())
    if settings.get('instance_dir') != str(instance):
        raise ValueError('Installation record belongs to another directory; use the original installation')
    if settings.get('release') != RELEASE and not allow_other_release:
        raise ValueError('Installed release ' + str(settings.get('release')) + ' differs from this setup ('
                         + RELEASE + '); from the new release checkout run: sudo bash opencj.sh upgrade')
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
                if os.geteuid() != 0:
                    raise ValueError('Run with sudo: setup creates restricted Linux service users')
                settings = initialize_instance(instance, supplied)
            if args.check and switched_off(instance, settings):
                print(f"{settings['name']} is off (on demand); start it to check it.")
            elif args.check:
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
