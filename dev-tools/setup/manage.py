"""Change an installed server's settings, upgrade all servers to this release, or refresh a copy."""

import argparse
import gzip
import tempfile
import time
from contextlib import contextmanager, nullcontext
from datetime import datetime, timezone
import os
from pathlib import Path
import re
import shutil
import sys

from configuration import collect_auth_token
from configuration import RELEASE, ask, ask_int, ask_on_demand, ask_port, ask_yes_no, collect_discord
from configuration import check_discord_channels, check_on_demand, collect_downloads, prompt, safe_cvar, validate_discord, validate_downloads
from operations import operation_lock, read_json, run, save_json
import install
import linux_accounts
import maintenance
import migration
import source as source_export
import service_control
from database_maintenance import DatabaseMaintenance
import website as managed_website

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'server-db/tools'))
import migrate
from runtime_access import quote_identifier

PASSWORD_MIN_CHARACTERS = 8
UPGRADE_FREE_RESERVE_GIB = 2
UPGRADE_BACKUP_LIMIT_GIB = 50
SERVICE_START_TIMEOUT_SECONDS = 300
RESTORE_TIMEOUT_SECONDS = 7200
RESTORE_CHUNK_BYTES = 1024 * 1024


def timestamp():
    return datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')


def host_plan(host):
    plan = read_json(host / 'host-setup.json')
    if plan.get('host_dir') != str(host):
        raise RuntimeError('Host plan belongs to another directory')
    return plan


def owns_database(settings):
    return settings['database']['mode'] == 'new'


def start_services(instance, settings, *, recreate=False, active_map=''):
    """Recreate changed services and wait for the game; remove services that were switched off.

    Only the game server (and its database) is waited for; optional services start
    without blocking (see install.start_optional_services).
    """
    if recreate and owns_database(settings):
        install.compose(instance, settings, 'up', '-d', '--wait', 'db', timeout=360)
    recreation = ['--force-recreate', '--no-deps'] if recreate else []
    install.compose(instance, settings, 'up', '-d', *recreation, '--remove-orphans', '--wait', '--wait-timeout',
                    str(SERVICE_START_TIMEOUT_SECONDS), 'server', log=instance / 'setup.log',
                    timeout=SERVICE_START_TIMEOUT_SECONDS + 60)
    if recreate:
        services = install.optional_services(settings)
        if services:
            install.compose(instance, settings, 'up', '-d', '--force-recreate', '--no-deps', *services)
        service_control.verify_running_files(instance, settings)
    else:
        install.start_optional_services(instance, settings)
    service_control.restore_map(instance, settings, active_map)
    if settings.get('website'):
        managed_website.start(instance, settings)


def stop_held(instance, settings):
    install.compose(instance, settings, 'stop', '--timeout', str(install.STOP_GRACE_SECONDS),
                    *install.held_services(settings), log=instance / 'setup.log')


def connected_players(instance, settings):
    """Refuse an unknown console result instead of treating it as an empty server."""
    return len(service_control.active_game(instance, settings)['players'])


def start_instance(host, name):
    """Start a server (normally an on-demand test server) and wait until players can join."""
    instance = host / name
    settings = install.load_installation(instance)
    service_control.require_available(instance)
    if (instance / 'pending-configuration.json').exists():
        configure_instance(host, name, apply_pending=True)
        settings = install.load_installation(instance)
        if (instance / 'pending-configuration.json').exists():
            return
    with operation_lock(instance / '.setup.lock'):
        install.verify_managed_files(instance, settings)
        if install.server_is_running(instance, settings):
            (instance / install.HOLD_RECORD).unlink(missing_ok=True)
            print(name + ' is already running.')
            return
        print('Starting ' + name + '...', flush=True)
        start_services(instance, settings)
        install.check_ready(instance, settings)
        (instance / install.HOLD_RECORD).unlink(missing_ok=True)
    print(name + ' is running on port ' + str(settings['port'])
          + ('. Switch it off again with: sudo opencj stop ' + name if settings.get('on_demand') else '.'))


def stop_instance(host, name, *, assume_yes):
    """Stop a server on purpose, without alerts.

    On demand: everything stops, its own database included, until `opencj start`.
    Always-on (for example to stop an exploit): only the game server and its Discord
    bridge stop; the database keeps serving the website and backups. It stays stopped
    until `opencj start` or the next reboot, after which the watchdog starts it again.
    """
    instance = host / name
    settings = install.load_installation(instance)
    with operation_lock(instance / '.setup.lock'):
        if install.switched_off(instance, settings) or install.held(instance, settings):
            print(name + ' is already stopped.')
            return
        players = connected_players(instance, settings)
        if players and not assume_yes and not ask_yes_no(
                str(players) + ' player(s) are connected and will be disconnected. Stop anyway?', False):
            raise SystemExit('Nothing was changed.')
        if settings.get('on_demand'):
            install.stop_services(instance, settings)
            print(name + ' is off. Start it again with: sudo opencj start ' + name)
            return
        # Recorded first, so the watchdog never sees an unexplained stop.
        save_json(instance / install.HOLD_RECORD, {'boot_id': install.current_boot(), 'stopped': timestamp()})
        stop_held(instance, settings)
    print(name + '\'s game server is stopped; the database, website and backups keep running. No alerts are'
          ' sent for it. It starts again with: sudo opencj start ' + name + ', or by itself after the next reboot.')


def on_demand_allowed(plan, settings):
    """Whether this server may be switched off; prints why not (the website or another server needs it)."""
    others = [item for item in plan['instances'] if item['name'] != settings['name']]
    try:
        check_on_demand([*others, {**settings, 'on_demand': True}])
    except ValueError as error:
        print('Note: ' + str(error) + '.', flush=True)
        return False
    return True


def ask_map(current):
    def parse(text):
        if not re.fullmatch(r'[a-z0-9_]+', text):
            raise ValueError('map names use lowercase letters, digits and underscores')
        return text
    return ask('Start map', current, parse=parse)


def collect_changes(settings, other_ports, *, can_be_on_demand=True):
    """Ask each changeable setting with its current value as the default."""
    changed = dict(settings)

    def parse_hostname(text):
        return safe_cvar(text)

    def parse_port(text):
        port = int(text)
        if port in other_ports:
            raise ValueError('another server on this machine uses that port')
        if not 1024 <= port <= 65535:
            raise ValueError('use a port from 1024 to 65535')
        return port

    changed['hostname'] = ask('Server display name', settings['hostname'], parse=parse_hostname)
    changed['port'] = ask('Game port', settings['port'], parse=parse_port)
    changed['address'] = ask('Address players connect to, for example eu.opencj.org ("none" for the IP address)',
                             settings.get('address') or 'none', parse=parse_address)
    changed['slots'] = ask_int('Player slots', settings['slots'], 1, 32)
    changed['public'] = ask_yes_no('Public access without a join password?', settings['public'])
    if changed['public']:
        changed['auth_token'] = collect_auth_token(settings.get('auth_token', ''))
    changed['map'] = ask_map(settings['map'])
    print('Map downloads are currently: ' + settings['downloads']['mode'], flush=True)
    if ask_yes_no('Change map downloads?', False):
        changed['downloads'] = validate_downloads(collect_downloads(settings['name'], public=changed['public']))
    print('Discord bridge is currently: ' + ('on' if settings['discord']['enabled'] else 'off'), flush=True)
    if ask_yes_no('Change the Discord bridge?', False):
        changed['discord'] = validate_discord(collect_discord(settings['name']))
    if changed['public'] != settings['public']:
        # A server becoming private gets a new join password; a public one has none.
        changed['join_password'] = '' if changed['public'] else os.urandom(12).hex()
    if not changed['public']:
        changed['join_password'] = ask_password('Join password', changed['join_password'])
    changed['rcon_password'] = ask_password('Administration (rcon) password', settings['rcon_password'])
    on_demand = ask_on_demand(settings['name'], settings.get('on_demand', False)) if can_be_on_demand else False
    if on_demand != settings.get('on_demand', False):
        changed['on_demand'] = on_demand
    if owns_database(settings) and ask_yes_no('Change backups, off-site copies, run pruning or IP-country updates?',
                                              False):
        changed.update(maintenance.collect_database_maintenance(settings['name'], owns_database=True))
        changed['backups'] = maintenance.backup_policy(changed)
        changed['pruning'] = maintenance.prune_policy(changed)
        changed['geoip'] = maintenance.geoip_policy(changed)
        if changed['geoip']['enabled'] and not settings['geoip'].get('user'):
            changed['geoip']['user'] = 'geoip_' + os.urandom(6).hex()
        elif changed['geoip']['enabled']:
            changed['geoip']['user'] = settings['geoip']['user']
    if settings.get('website') and ask_yes_no('Change website settings (domains, game address, invite)?', False):
        current = settings['website']
        updated = managed_website.collect_website(changed['port'], current=current,
                                                  game_address=changed['address'])
        # The database account, local port and generated identities stay the same.
        changed['website'] = {**current, **{key: updated[key] for key in
                                            ('domain', 'aliases', 'connect_address', 'discord_invite')},
                              'acme_email': updated.get('acme_email', '')}
    return changed


def parse_address(text):
    return '' if text == 'none' else managed_website.validate_domain(text.strip())


def ask_password(label, current):
    """keep, new (random) or a typed password; the current one is in the installation folder."""
    def parse(text):
        if text == 'keep':
            return current
        if text == 'new':
            return os.urandom(12).hex()
        if len(text) < PASSWORD_MIN_CHARACTERS:
            raise ValueError('use at least ' + str(PASSWORD_MIN_CHARACTERS) + ' characters, "keep" or "new"')
        return safe_cvar(text)
    return ask(label + ': keep / new (random) / or type one', 'keep', parse=parse)


def configure_instance(host, name, *, apply_pending=False):
    """Apply operator changes to one server; refuse when its generated files were edited by hand."""
    instance = host / name
    settings = install.load_installation(instance)
    service_control.require_available(instance)
    plan = host_plan(host)
    other_ports = {item['port'] for item in plan['instances'] if item['name'] != name}
    with operation_lock(instance / '.setup.lock'):
        pending = instance / 'pending-configuration.json'
        record = read_json(pending) if pending.exists() else {}
        if record.get('applying'):
            service_control.verify_configuration_retry(instance, settings, record)
        else:
            install.verify_managed_files(instance, settings)
        was_off = install.switched_off(instance, settings)
        was_held = install.held(instance, settings)
        if record.get('applying'):
            was_off = record.get('was_off', was_off)
            was_held = record.get('was_held', was_held)
        defaults = settings
        if pending.exists():
            record = read_json(pending)
            if not record.get('applying') and (record['base_hashes'] != settings['managed_hashes']
                                               or record['release'] != settings['release']):
                raise RuntimeError('Pending settings belong to an older configuration; review them before continuing')
            defaults = record['settings']
        if apply_pending or record.get('applying'):
            changed = defaults
        else:
            changed = collect_changes(
                defaults, other_ports, can_be_on_demand=on_demand_allowed(plan, defaults))
        if changed['port'] in other_ports:
            raise RuntimeError('Another server now uses the requested port; review pending configuration')
        if changed == settings and not pending.exists():
            print('Nothing changed.')
            return
        check_on_demand([*(item for item in plan['instances'] if item['name'] != name), changed])
        check_discord_channels([*(item for item in plan['instances'] if item['name'] != name), changed])
        try:
            active = service_control.active_game(instance, settings)
        except (RuntimeError, OSError) as error:
            print('Connected players: unknown; immediate restart is unavailable (' + str(error) + ').', flush=True)
            active = None
        apply_now = False
        if active is not None:
            count = len(active['players'])
            print(str(count) + ' connected player(s). Active map: ' + (active['map'] or 'server stopped'), flush=True)
            if apply_pending and not active['map']:
                apply_now = True
            else:
                apply_now = ask_yes_no('Apply these changes now by restarting the server?', False)
        if not apply_now:
            if not record.get('applying'):
                save_json(pending, {'base_hashes': settings['managed_hashes'], 'release': settings['release'],
                                    'settings': changed})
            print('Changes saved but not applied. Apply them with: sudo opencj start ' + name, flush=True)
            return
        # A later arrival was not included in the operator's decision.
        latest = service_control.active_game(instance, settings)
        if latest['players'] != active['players'] and not ask_yes_no(
                str(len(latest['players'])) + ' player(s) are connected now. Restart anyway?', False):
            if not record.get('applying'):
                save_json(pending, {'base_hashes': settings['managed_hashes'], 'release': settings['release'],
                                    'settings': changed})
            print('Changes saved but not applied; connected players were preserved.')
            return
        active = latest
        if not record.get('applying'):
            save_json(pending, {'base_hashes': settings['managed_hashes'], 'release': settings['release'],
                                'settings': changed, 'applying': True, 'active_map': active['map'],
                                'was_off': was_off, 'was_held': was_held})
        changed['state'] = 'ready'
        linux_accounts.ensure_accounts(changed)
        newly_enabled = [service for service in ('discord', 'geoip')
                         if changed[service]['enabled'] and not settings[service]['enabled']]
        if newly_enabled:
            install.build_optional_images(instance, changed)
        if 'geoip' in newly_enabled:
            install.compose(instance, changed, 'up', '-d', '--wait', 'db', timeout=360)
            install.provision_geoip(instance, changed)
        install.write_instance_files(instance, changed, replace=True)
        if changed.get('website') and changed['website'] != settings.get('website'):
            managed_website.prepare(instance, changed, replace=True)
        install.save_installation(instance, changed)
        maintenance.prepare_offsite(instance, changed)
        maintenance.configure_instance_jobs(instance, changed)
        print('Restarting ' + name + ' with the new settings...', flush=True)
        resume_map = read_json(pending).get('active_map', active['map'])
        start_services(instance, changed, recreate=True, active_map=resume_map)
        install.check_ready(instance, changed)
        # The new settings were checked while running; an on-demand server that was off stays off.
        off_again = was_off and changed.get('on_demand', False)
        if off_again:
            install.stop_services(instance, changed)
        elif was_held and not changed.get('on_demand'):
            stop_held(instance, changed)
            off_again = True
    for item in plan['instances']:
        if item['name'] == name:
            # The plan drives the firewall (game port, website ports 80/443) on later runs.
            item.update({key: changed[key] for key in ('hostname', 'port', 'address', 'slots', 'public', 'map',
                                                       'downloads', 'discord')})
            item['on_demand'] = changed.get('on_demand', False)
            if changed.get('website'):
                item['website'] = changed['website']
    save_json(host / 'host-setup.json', plan)
    from firewall import configure_firewall
    configure_firewall(plan, plan['instances'])
    if changed['address'] != settings.get('address', '') or changed.get('website') != settings.get('website'):
        import dns_guide
        dns_guide.print_records(plan)
        print('\nCurrent state (check again any time with: sudo opencj dns):', flush=True)
        dns_guide.report(plan)
    if changed['join_password'] != settings['join_password'] and changed['join_password']:
        print('The join password changed; it is in ' + str(instance / 'join-password'))
    if changed['rcon_password'] != settings['rcon_password']:
        print('The administration password changed; it is in ' + str(instance / 'rcon-password'))
    pending.unlink(missing_ok=True)
    if off_again:
        print(name + ' has the new settings and is off again. Start it with: sudo opencj start ' + name)
    elif changed.get('on_demand') and not settings.get('on_demand'):
        print(name + ' now runs with the new settings. It stays on until: sudo opencj stop ' + name)
    else:
        print(name + ' now runs with the new settings.')


def configure_alerts(host):
    """Set, change or remove the Discord webhook for alerts, then send a test message."""
    record = host / 'host-setup.json'
    with operation_lock(host / '.host-setup.lock'):
        plan = host_plan(host)
        alerts = plan.setdefault('alerts', {'discord_webhook': ''})
        print('Alerts currently go to: ' + ('a Discord webhook' if alerts['discord_webhook'] else 'the journal only'),
              flush=True)
        maintenance.print_webhook_help()

        def parse(text):
            if text == 'keep':
                return alerts['discord_webhook']
            if text == 'off':
                return ''
            return maintenance.validate_webhook(text)
        alerts['discord_webhook'] = ask('New webhook URL, "off" or "keep"', 'keep', parse=parse)
        save_json(record, plan)
    maintenance.send_alert(host, 'Test alert: OpenCJ alerts for this machine arrive here.')
    print('A test alert was sent' + (' to the webhook.' if alerts['discord_webhook'] else ' to the journal.'))
    print_outside_check_command(plan)


def outside_check_targets(plan):
    """What another machine should check: each publicly reachable game server and the website."""
    import dns_guide
    addresses = dns_guide.public_addresses(plan)['A']
    fallback = addresses[0] if addresses else '<this server\'s address>'
    targets = []
    for settings in plan['instances']:
        # An on-demand server is off most of the time; that is not an outage.
        if settings.get('bind_ip', '0.0.0.0') != '127.0.0.1' and not settings.get('on_demand'):
            targets.append('game:' + (settings.get('address') or fallback) + ':' + str(settings['port']))
        if settings.get('website', {}).get('domain'):
            targets.append('web:https://' + settings['website']['domain'] + '/')
    return targets


def print_outside_check_command(plan):
    """The watchdog here cannot report this whole machine going down; another machine must."""
    targets = outside_check_targets(plan)
    if not targets:
        return
    name = plan['instances'][0]['name']
    print('\nThis machine cannot report its own outage (power, network, provider). On another machine,'
          ' normally the external backup server, run from its opencj-core checkout:\n'
          '  sudo bash opencj.sh monitor --name ' + name + ''.join(' --target ' + target for target in targets)
          + '\nIt asks for the alert webhook and then checks every 2 minutes.', flush=True)


def applied_migrations(instance, settings, *, allow_pending=False):
    """Accept a valid older migration prefix only during upgrade preflight."""
    with install.database_client(instance, settings) as db:
        if not allow_pending:
            return install.check_database(db)
        rows = migrate.read_ledger(db)
        migrate.validate_history(rows, migrate.load_migrations())
        if not rows:
            raise RuntimeError('Upgrade requires an initialized migration ledger')
        return len(rows)


def upgrade_backup(instance, settings, upgrade):
    """A full dump before any schema change; the restore path if the new release must be abandoned."""
    directory = instance / 'upgrade-backups'
    directory.mkdir(mode=0o700, exist_ok=True)
    target = directory / (upgrade['from'] + '-' + timestamp() + '.sql.gz')
    partial = target.with_name('.' + target.name + '.partial')
    partial.unlink(missing_ok=True)
    try:
        maintenance.dump_database(instance, settings, partial,
                                  byte_limit=UPGRADE_BACKUP_LIMIT_GIB * maintenance.GIB,
                                  reserve_bytes=UPGRADE_FREE_RESERVE_GIB * maintenance.GIB)
        os.replace(partial, target)
    finally:
        partial.unlink(missing_ok=True)
    upgrade['backup'] = str(target)


def upgrade_database(instance, settings):
    """Apply this release's schema migrations and its reviewed account policies (owners only)."""
    with install.database_client(instance, settings, administrator=True) as db:
        migrate.lock_database(db, settings['database']['name'])
        migrate.apply_migrations(db, migrate.load_migrations())
        install.provision_game_account(db, settings)
        if settings.get('website'):
            managed_website.provision(db, settings)


def upgrade_instance(instance, settings):
    """Upgrade one server in resumable stages recorded in its installation record."""
    upgrade = settings.setdefault('upgrade', {'from': settings['release'], 'to': RELEASE, 'stage': 'start'})
    if upgrade['to'] != RELEASE:
        raise RuntimeError('An upgrade to ' + upgrade['to'] + ' is unfinished; run that release\'s setup first')
    print('Upgrading ' + settings['name'] + ' from ' + upgrade['from'] + ' to ' + RELEASE + '...', flush=True)
    if upgrade['stage'] == 'start':
        install.verify_managed_files(instance, settings)
        upgrade['previous_image'] = settings['image']
        upgrade['previous_image_id'] = settings['image_id']
        upgrade['previous_optional_images'] = {key: settings[key] for key in ('discord_image', 'geoip_image')
                                               if settings.get(key)}
        upgrade['migrations_before'] = applied_migrations(instance, settings, allow_pending=True)
        upgrade['backup'] = ''
        if owns_database(settings):
            upgrade_backup(instance, settings, upgrade)
        upgrade['stage'] = 'backed-up'
        install.save_installation(instance, settings)
    if upgrade['stage'] == 'backed-up':
        # Keep all writers fenced until every member has matching schema and code.
        settings['release'] = RELEASE
        settings['image'] = settings['project'] + ':' + RELEASE
        install.build_release(instance, settings)
        upgrade['stage'] = 'built'
        install.save_installation(instance, settings)
    if upgrade['stage'] == 'built':
        if owns_database(settings):
            upgrade_database(instance, settings)
        upgrade['migrations_after'] = applied_migrations(instance, settings)
        upgrade['stage'] = 'database-ready'
        install.save_installation(instance, settings)
    if upgrade['stage'] == 'database-ready':
        receipt = instance / service_control.UPGRADE_FILES_RECORD
        if not receipt.exists():
            save_json(receipt, {'applying': True, 'base_hashes': settings['managed_hashes']})
        install.write_instance_files(instance, settings, replace=True)
        if settings.get('website'):
            managed_website.prepare(instance, settings, replace=True)
        install.save_installation(instance, settings)
        # Activation is coordinated for the complete database group below.
        upgrade['stage'] = 'prepared'
        install.save_installation(instance, settings)


def upgrade_host(host):
    """Upgrade database groups while all their writers are stopped, including retries."""
    plan = host_plan(host)
    owners = []
    for name in plan.get('completed', []):
        instance = host / name
        settings = install.load_installation(instance, allow_other_release=True)
        owner = Path(settings['database'].get('owner_instance', instance))
        if owner not in owners:
            owners.append(owner)
    for owner in owners:
        members = []
        for directory in sorted(host.iterdir()):
            if not (directory / 'installation.json').is_file():
                continue
            settings = install.load_installation(directory, allow_other_release=True)
            if directory == owner or settings['database'].get('owner_instance') == str(owner):
                members.append((directory, settings))
        if all(settings['release'] == RELEASE and 'upgrade' not in settings for directory, settings in members):
            if not (owner / service_control.MAINTENANCE_RECORD).exists():
                continue
        # Owners migrate first, but no game starts until all group members are ready.
        members.sort(key=lambda member: member[0] != owner)
        with DatabaseMaintenance(owner, 'upgrade') as maintenance_group:
            for directory, settings in members:
                if settings['release'] != RELEASE or 'upgrade' in settings:
                    upgrade_instance(directory, settings)
            maintenance_group.resume(start_services)
            for directory, settings in members:
                settings.pop('upgrade', None)
                install.save_installation(directory, settings)
                (directory / service_control.UPGRADE_FILES_RECORD).unlink(missing_ok=True)
                maintenance.configure_instance_jobs(directory, settings)
    maintenance.install_command_link()
    print('All servers run ' + RELEASE + '; `sudo opencj` now uses this release.')


def import_dump(instance, settings, bundle, manifest):
    """Replace the copy's database with the snapshot and prove that every table matches."""
    name = settings['database']['name']
    if manifest['database'] != name:
        raise RuntimeError('Snapshot database ' + manifest['database'] + ' differs from ' + name)
    with install.database_client(instance, settings, administrator=True, schema='information_schema') as db:
        db.query('DROP DATABASE IF EXISTS ' + quote_identifier(name) + ';\nCREATE DATABASE ' + quote_identifier(name) + ';')
    container = install.compose(instance, settings, 'ps', '--quiet', 'db')
    command = ['docker', 'exec', '-i', container, 'sh', '-c',
               'MYSQL_PWD="${MYSQL_ROOT_PASSWORD:-$(cat \"$MYSQL_ROOT_PASSWORD_FILE\")}" exec mysql -u root']
    with (bundle / 'database.sql').open('rb') as incoming:
        run(command, stdin=incoming, timeout=7200, log=instance / 'refresh.log')
    with install.database_client(instance, settings, administrator=True) as db:
        if source_export.database_inventory(db) != manifest['tables']:
            raise RuntimeError('Refreshed database differs from the snapshot; inspect ' + str(instance / 'refresh.log'))
    upgrade_database(instance, settings)


@contextmanager
def validated_backup(instance, backup):
    """Fully decompress and check CRC/EOF into a bounded private file before touching SQL."""
    deadline = time.monotonic() + RESTORE_TIMEOUT_SECONDS
    maximum_bytes = UPGRADE_BACKUP_LIMIT_GIB * maintenance.GIB
    reserve_bytes = UPGRADE_FREE_RESERVE_GIB * maintenance.GIB
    with tempfile.TemporaryFile(dir=instance) as sql:
        try:
            with gzip.open(backup, 'rb') as compressed:
                total_bytes = 0
                while True:
                    chunk = compressed.read(RESTORE_CHUNK_BYTES)
                    if not chunk:
                        break
                    total_bytes += len(chunk)
                    if total_bytes > maximum_bytes or shutil.disk_usage(instance).free < len(chunk) + reserve_bytes:
                        raise RuntimeError('Backup exceeds restore space limits; current database preserved')
                    if time.monotonic() >= deadline:
                        raise RuntimeError('Backup validation timed out; current database preserved')
                    sql.write(chunk)
        except (EOFError, gzip.BadGzipFile) as error:
            raise RuntimeError('Backup archive is damaged; current database preserved') from error
        if not total_bytes:
            raise RuntimeError('Backup contains no SQL; current database preserved')
        sql.seek(0)
        yield sql


def restore_backup(host, name, backup, *, assume_yes):
    """Validate first, fence all writers, then replace SQL with a checked import."""
    instance = host / name
    settings = install.load_installation(instance)
    if not owns_database(settings):
        raise ValueError(name + ' shares another server database; restore it on its owner')
    backup = backup.resolve()
    if not backup.is_file() or not backup.name.endswith('.sql.gz'):
        raise ValueError('Supply a .sql.gz backup')
    print('This replaces ALL data of ' + name + '. All servers sharing its database pause; a safety copy is kept.')
    if not assume_yes and not ask_yes_no('Restore now?', False):
        raise SystemExit('Nothing was changed.')
    with validated_backup(instance, backup) as sql:
        with DatabaseMaintenance(instance, 'restore', assume_yes=assume_yes) as maintenance_group:
            journal = maintenance_group.journal
            backup_hash = migration.sha256_file(backup)
            if journal.get('backup_sha256', backup_hash) != backup_hash:
                raise RuntimeError('An unfinished restore used a different backup; preserve its recovery record')
            if 'safety' not in journal:
                safety = instance / 'upgrade-backups' / ('before-restore-' + timestamp() + '.sql.gz')
                safety.parent.mkdir(mode=0o700, exist_ok=True)
                partial = safety.with_name('.' + safety.name + '.partial')
                try:
                    maintenance.dump_database(instance, settings, partial,
                                              byte_limit=UPGRADE_BACKUP_LIMIT_GIB * maintenance.GIB,
                                              reserve_bytes=UPGRADE_FREE_RESERVE_GIB * maintenance.GIB)
                    os.replace(partial, safety)
                finally:
                    partial.unlink(missing_ok=True)
                journal.update(safety=str(safety), backup_sha256=backup_hash)
                save_json(maintenance_group.record, journal)
            print('Safety copy of the original data: ' + journal['safety'], flush=True)
            if not journal.get('data_ready'):
                name_sql = quote_identifier(settings['database']['name'])
                with install.database_client(instance, settings, administrator=True, schema='information_schema') as db:
                    db.query('DROP DATABASE IF EXISTS ' + name_sql + ';\nCREATE DATABASE ' + name_sql + ';')
                container = install.compose(instance, settings, 'ps', '--quiet', 'db')
                command = ['docker', 'exec', '-i', container, 'sh', '-c',
                           'MYSQL_PWD="${MYSQL_ROOT_PASSWORD:-$(cat "$MYSQL_ROOT_PASSWORD_FILE")}" exec mysql -u root']
                run(command, stdin=sql, timeout=7200, log=instance / 'restore.log')
                upgrade_database(instance, settings)
                applied_migrations(instance, settings)
                # A later activation failure must never re-import over progress
                # accepted by a game that briefly resumed successfully.
                journal['data_ready'] = True
                save_json(maintenance_group.record, journal)
            maintenance_group.resume(start_services)
    print(name + ' runs with the data from ' + backup.name + '.')


def refresh_instance(host, name, *, assume_yes):
    """Replace a copied server's database and runtime files with a fresh copy of its source."""
    instance = host / name
    settings = install.load_installation(instance)
    source_name = settings.get('copy_source')
    if not source_name:
        raise ValueError(name + ' was not created as a copy of another server')
    print('This replaces all data of ' + name + ' (database, saves, checkpoint drafts) with a fresh copy of '
          + source_name + '. ' + source_name + ' pauses for about a minute; this is refused while players'
          ' are connected to it.', flush=True)
    if not assume_yes and not ask_yes_no('Continue?', False):
        raise SystemExit('Nothing was changed.')
    with DatabaseMaintenance(instance, 'refresh', assume_yes=assume_yes) as maintenance_group:
        journal = maintenance_group.journal
        if 'refresh_bundle' not in journal:
            journal['refresh_bundle'] = str(instance / 'migration' / ('refresh-' + timestamp()))
            journal['previous_runtime'] = str(instance / ('runtime.previous-' + timestamp()))
            save_json(maintenance_group.record, journal)
        bundle = Path(journal['refresh_bundle'])
        bundle.parent.mkdir(mode=0o700, exist_ok=True)
        if not journal.get('data_ready'):
            # A completed export is reused; a retry must not mix one snapshot's SQL
            # with another snapshot's saves and checkpoint drafts.
            source_export.export_source(host / source_name, bundle, intent='rehearsal', without_assets=True)
            manifest = migration.validate_bundle(bundle)
            import_dump(instance, settings, bundle, manifest)
            restore_refresh_runtime(instance, settings, bundle, Path(journal['previous_runtime']))
            journal['data_ready'] = True
            save_json(maintenance_group.record, journal)
        maintenance_group.resume(start_services)
        shutil.rmtree(bundle)
    print(name + ' now holds a fresh copy of ' + source_name + '. Its previous runtime files are kept for 30 days'
          ' in ' + str(instance) + '/runtime.previous-*.')


def restore_refresh_runtime(instance, settings, bundle, previous):
    """Keep the original runtime once, including a crash immediately after its rename."""
    runtime = instance / 'runtime'
    if not previous.exists():
        os.replace(runtime, previous)
    runtime.mkdir(mode=0o700, exist_ok=True)
    os.chown(runtime, settings['uid'], settings['gid'])
    migration.restore_runtime(instance, settings, bundle=bundle)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host-dir', type=Path, default=Path('/srv/opencj'))
    commands = parser.add_subparsers(dest='command', required=True)
    configure = commands.add_parser('configure', help='Change a server\'s name, access, passwords, slots, port, map,'
                                                      ' downloads or Discord')
    configure.add_argument('name')
    start = commands.add_parser('start', help='Start a server that is off (for example acceptance or map-test)')
    start.add_argument('name')
    stop = commands.add_parser('stop', help='Switch an on-demand server off, its database included')
    stop.add_argument('name')
    stop.add_argument('--yes', action='store_true', help='Stop even when players are connected')
    commands.add_parser('status', help='Check everything on this machine, then list what needs attention')
    commands.add_parser('alerts', help='Set or change the Discord webhook for alerts and send a test alert')
    commands.add_parser('dns', help='DNS records to create for the website and servers, and whether they point here')
    commands.add_parser('upgrade', help='Upgrade all servers on this machine to this checkout\'s release')
    refresh = commands.add_parser('refresh', help='Replace a copied server\'s data with a fresh copy of its source')
    refresh.add_argument('name')
    refresh.add_argument('--yes', action='store_true', help='Do not ask for confirmation')
    restore = commands.add_parser('restore', help='Replace a server\'s database with a .sql.gz backup')
    restore.add_argument('name')
    restore.add_argument('backup', type=Path)
    restore.add_argument('--yes', action='store_true', help='Do not ask for confirmation')
    args = parser.parse_args()
    os.umask(0o077)
    if os.geteuid() != 0:
        parser.error('Run with sudo')
    host = args.host_dir.expanduser().resolve()
    # Membership and port allocation must not change while maintenance/configuration
    # coordinates several instances. Per-instance locks also exclude scheduled jobs.
    mutations = ('configure', 'start', 'stop', 'upgrade', 'restore', 'refresh')
    lock = operation_lock(host / '.host-setup.lock') if args.command in mutations else nullcontext()
    with lock:
        if args.command == 'configure':
            configure_instance(host, args.name)
        elif args.command == 'start':
            start_instance(host, args.name)
        elif args.command == 'stop':
            stop_instance(host, args.name, assume_yes=args.yes)
        elif args.command == 'status':
            import status
            status.show_status(host)
        elif args.command == 'alerts':
            configure_alerts(host)
        elif args.command == 'dns':
            import dns_guide
            dns_guide.show(host_plan(host))
        elif args.command == 'upgrade':
            upgrade_host(host)
        elif args.command == 'restore':
            restore_backup(host, args.name, args.backup, assume_yes=args.yes)
        else:
            refresh_instance(host, args.name, assume_yes=args.yes)


if __name__ == '__main__':
    main()
