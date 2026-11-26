"""Change an installed server's settings, upgrade all servers to this release, or refresh a copy."""

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import os
from pathlib import Path
import re
import shutil
import sys

from configuration import RELEASE, ask, ask_int, ask_on_demand, ask_port, ask_yes_no, collect_discord
from configuration import check_discord_channels, check_on_demand, collect_downloads, prompt, safe_cvar, validate_discord, validate_downloads
from operations import operation_lock, read_json, run, save_json
import install
import linux_accounts
import maintenance
import migration
import source as source_export
import website as managed_website

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'server-db/tools'))
import migrate
from runtime_access import quote_identifier

PASSWORD_MIN_CHARACTERS = 8
UPGRADE_FREE_RESERVE_GIB = 2
UPGRADE_BACKUP_LIMIT_GIB = 50
SERVICE_START_TIMEOUT_SECONDS = 300


def timestamp():
    return datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')


def host_plan(host):
    plan = read_json(host / 'host-setup.json')
    if plan.get('host_dir') != str(host):
        raise RuntimeError('Host plan belongs to another directory')
    return plan


def owns_database(settings):
    return settings['database']['mode'] == 'new'


def start_services(instance, settings):
    """Recreate changed services and wait for the game; remove services that were switched off.

    Only the game server (and its database) is waited for; optional services start
    without blocking (see install.start_optional_services).
    """
    install.compose(instance, settings, 'up', '-d', '--remove-orphans', '--wait', '--wait-timeout',
                    str(SERVICE_START_TIMEOUT_SECONDS), 'server', log=instance / 'setup.log',
                    timeout=SERVICE_START_TIMEOUT_SECONDS + 60)
    install.start_optional_services(instance, settings)
    if settings.get('website'):
        managed_website.start(instance, settings)


@contextmanager
def running_for_maintenance(instance, settings):
    """Start an on-demand server that is off for the duration of the work, then switch it off again.

    After a failure it is left running, so the problem can be inspected.
    """
    was_off = install.switched_off(instance, settings)
    if was_off:
        print(settings['name'] + ' is off; starting it for this change...', flush=True)
        start_services(instance, settings)
    yield
    if was_off and settings.get('on_demand'):
        install.stop_services(instance, settings)
        print(settings['name'] + ' is off again.', flush=True)


def connected_players(instance, settings):
    """Number of players on the server now; 0 when its console does not answer."""
    import status
    container = install.compose(instance, settings, 'ps', '--quiet', 'server')
    players = status.live_server(container)[1] if container else '0'
    return int(players) if players.isdigit() else 0


def start_instance(host, name):
    """Start a server (normally an on-demand test server) and wait until players can join."""
    instance = host / name
    settings = install.load_installation(instance)
    with operation_lock(instance / '.setup.lock'):
        install.verify_managed_files(instance, settings)
        if install.server_is_running(instance, settings):
            print(name + ' is already running.')
            return
        print('Starting ' + name + '...', flush=True)
        start_services(instance, settings)
        install.check_ready(instance, settings)
    print(name + ' is running on port ' + str(settings['port'])
          + ('. Switch it off again with: sudo opencj stop ' + name if settings.get('on_demand') else '.'))


def stop_instance(host, name, *, assume_yes):
    """Switch an on-demand server off completely, its own database included; its data is kept."""
    instance = host / name
    settings = install.load_installation(instance)
    if not settings.get('on_demand'):
        raise ValueError(name + ' always runs, and the watchdog would report it as down. To start it only when'
                         ' needed, first answer yes to "Keep ' + name + ' off" in: sudo opencj configure ' + name)
    with operation_lock(instance / '.setup.lock'):
        if install.switched_off(instance, settings):
            print(name + ' is already off.')
            return
        players = connected_players(instance, settings)
        if players and not assume_yes and not ask_yes_no(
                str(players) + ' player(s) are connected and will be disconnected. Stop anyway?', False):
            raise SystemExit('Nothing was changed.')
        install.stop_services(instance, settings)
    print(name + ' is off. Start it again with: sudo opencj start ' + name)


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


def configure_instance(host, name):
    """Apply operator changes to one server; refuse when its generated files were edited by hand."""
    instance = host / name
    settings = install.load_installation(instance)
    plan = host_plan(host)
    other_ports = {item['port'] for item in plan['instances'] if item['name'] != name}
    with operation_lock(instance / '.setup.lock'):
        install.verify_managed_files(instance, settings)
        was_off = install.switched_off(instance, settings)
        changed = collect_changes(settings, other_ports, can_be_on_demand=on_demand_allowed(plan, settings))
        if changed == settings:
            print('Nothing changed.')
            return
        check_discord_channels([*(item for item in plan['instances'] if item['name'] != name), changed])
        changed['state'] = 'ready'
        linux_accounts.ensure_accounts(changed)
        newly_enabled = [service for service in ('discord', 'geoip')
                         if changed[service]['enabled'] and not settings[service]['enabled']]
        if newly_enabled:
            install.build_optional_images(instance, changed)
        if 'geoip' in newly_enabled:
            install.provision_geoip(instance, changed)
        install.write_instance_files(instance, changed, replace=True)
        if changed.get('website') and changed['website'] != settings.get('website'):
            managed_website.prepare(instance, changed, replace=True)
        install.save_installation(instance, changed)
        maintenance.prepare_offsite(instance, changed)
        maintenance.configure_instance_jobs(instance, changed)
        print('Restarting ' + name + ' with the new settings...', flush=True)
        start_services(instance, changed)
        install.check_ready(instance, changed)
        # The new settings were checked while running; an on-demand server that was off stays off.
        off_again = was_off and changed.get('on_demand', False)
        if off_again:
            install.stop_services(instance, changed)
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


def applied_migrations(instance, settings):
    with install.database_client(instance, settings) as db:
        return install.check_database(db)


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


def roll_back(instance, settings, upgrade):
    """Return to the previous image when the schema did not change; otherwise explain the restore."""
    if upgrade.get('migrations_before') != upgrade.get('migrations_after'):
        raise RuntimeError('The new release failed after changing the database schema. The previous release'
                           ' cannot run on it. Fix the problem and rerun upgrade, or restore '
                           + upgrade['backup'] + ' with the previous release checkout.')
    settings['release'] = upgrade['from']
    settings['image'] = upgrade['previous_image']
    settings['image_id'] = upgrade['previous_image_id']
    # The bridge and the game speak one protocol per release, so they go back together.
    settings.update(upgrade.get('previous_optional_images', {}))
    install.write_instance_files(instance, settings, replace=True)
    start_services(instance, settings)
    settings.pop('upgrade')
    install.save_installation(instance, settings)
    raise RuntimeError('The new release did not start; ' + settings['name'] + ' runs the previous release'
                       ' again. Inspect ' + str(instance / 'setup.log') + '.')


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
        upgrade['migrations_before'] = applied_migrations(instance, settings)
        upgrade['backup'] = ''
        if owns_database(settings):
            upgrade_backup(instance, settings, upgrade)
        upgrade['stage'] = 'backed-up'
        install.save_installation(instance, settings)
    if upgrade['stage'] == 'backed-up':
        # Builds take longest; the old release keeps serving players meanwhile.
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
        install.write_instance_files(instance, settings, replace=True)
        if settings.get('website'):
            managed_website.prepare(instance, settings, replace=True)
        install.save_installation(instance, settings)
        try:
            start_services(instance, settings)
            install.check_ready(instance, settings)
        except (RuntimeError, OSError) as error:
            print('Start failed: ' + str(error), flush=True)
            roll_back(instance, settings, upgrade)
        settings.pop('upgrade')
        install.save_installation(instance, settings)
        maintenance.configure_instance_jobs(instance, settings)
    print(settings['name'] + ' runs ' + RELEASE + '.', flush=True)


def upgrade_host(host):
    """Upgrade every installed server in plan order: database owners come before servers sharing them."""
    plan = host_plan(host)
    for name in plan.get('completed', []):
        instance = host / name
        with operation_lock(instance / '.setup.lock'):
            settings = install.load_installation(instance, allow_other_release=True)
            if settings['release'] == RELEASE and 'upgrade' not in settings:
                print(name + ' already runs ' + RELEASE + '.', flush=True)
                continue
            with running_for_maintenance(instance, settings):
                upgrade_instance(instance, settings)
    maintenance.install_command_link()
    print('All servers run ' + RELEASE + '; `sudo opencj` now uses this release. Servers on other machines'
          ' that share a database here must be upgraded too.')


def import_dump(instance, settings, bundle, manifest):
    """Replace the copy's database with the snapshot and prove that every table matches."""
    name = settings['database']['name']
    if manifest['database'] != name:
        raise RuntimeError('Snapshot database ' + manifest['database'] + ' differs from ' + name)
    with install.database_client(instance, settings, administrator=True) as db:
        db.query('DROP DATABASE ' + quote_identifier(name) + ';\nCREATE DATABASE ' + quote_identifier(name) + ';')
    container = install.compose(instance, settings, 'ps', '--quiet', 'db')
    command = ['docker', 'exec', '-i', container, 'sh', '-c',
               'MYSQL_PWD="${MYSQL_ROOT_PASSWORD:-$(cat \"$MYSQL_ROOT_PASSWORD_FILE\")}" exec mysql -u root']
    with (bundle / 'database.sql').open('rb') as incoming:
        run(command, stdin=incoming, timeout=7200, log=instance / 'refresh.log')
    with install.database_client(instance, settings, administrator=True) as db:
        if source_export.database_inventory(db) != manifest['tables']:
            raise RuntimeError('Refreshed database differs from the snapshot; inspect ' + str(instance / 'refresh.log'))
    upgrade_database(instance, settings)


def restore_backup(host, name, backup, *, assume_yes):
    """Replace a server's database with a backup; the current state is dumped first as a safety copy."""
    instance = host / name
    settings = install.load_installation(instance)
    if not owns_database(settings):
        raise ValueError(name + ' shares another server\'s database; restore it on that server')
    backup = backup.resolve()
    if not backup.is_file() or not backup.name.endswith('.sql.gz'):
        raise ValueError('Supply a .sql.gz backup, for example from ' + str(instance / 'automatic-backups'))
    print('This replaces ALL data of ' + name + ' with ' + backup.name + '. Progress made after that backup is'
          ' lost (a safety copy of the current state is kept). Players are disconnected.', flush=True)
    if not assume_yes and not ask_yes_no('Restore now?', False):
        raise SystemExit('Nothing was changed.')
    with operation_lock(instance / '.setup.lock'), running_for_maintenance(instance, settings):
        safety = instance / 'upgrade-backups' / ('before-restore-' + timestamp() + '.sql.gz')
        safety.parent.mkdir(mode=0o700, exist_ok=True)
        maintenance.dump_database(instance, settings, safety,
                                  byte_limit=UPGRADE_BACKUP_LIMIT_GIB * maintenance.GIB,
                                  reserve_bytes=UPGRADE_FREE_RESERVE_GIB * maintenance.GIB)
        print('Safety copy of the current data: ' + str(safety), flush=True)
        install.compose(instance, settings, 'stop', 'server', *install.optional_services(settings), timeout=120)
        name_sql = quote_identifier(settings['database']['name'])
        with install.database_client(instance, settings, administrator=True) as db:
            db.query('DROP DATABASE ' + name_sql + ';\nCREATE DATABASE ' + name_sql + ';')
        container = install.compose(instance, settings, 'ps', '--quiet', 'db')
        command = ['sh', '-c', 'gzip -dc "$0" | docker exec -i "$1" sh -c '
                   '\'MYSQL_PWD="${MYSQL_ROOT_PASSWORD:-$(cat "$MYSQL_ROOT_PASSWORD_FILE")}" exec mysql -u root\'',
                   str(backup), container]
        run(command, timeout=7200, log=instance / 'restore.log')
        # The backup may predate later releases' migrations; bring the schema and grants up to date.
        upgrade_database(instance, settings)
        start_services(instance, settings)
        install.check_ready(instance, settings)
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
    with operation_lock(instance / '.setup.lock'), running_for_maintenance(instance, settings):
        bundle = instance / 'migration' / ('refresh-' + timestamp())
        bundle.parent.mkdir(mode=0o700, exist_ok=True)
        source_export.export_source(host / source_name, bundle, intent='rehearsal', without_assets=True)
        manifest = migration.validate_bundle(bundle)
        install.compose(instance, settings, 'stop', 'server', *(['discord'] if settings['discord']['enabled'] else []),
                        timeout=120)
        import_dump(instance, settings, bundle, manifest)
        runtime = instance / 'runtime'
        os.replace(runtime, instance / ('runtime.previous-' + timestamp()))
        runtime.mkdir(mode=0o700)
        os.chown(runtime, settings['uid'], settings['gid'])
        migration.restore_runtime(instance, settings, bundle=bundle)
        start_services(instance, settings)
        install.check_ready(instance, settings)
        shutil.rmtree(bundle)
    print(name + ' now holds a fresh copy of ' + source_name + '. Its previous runtime files are kept for 30 days'
          ' in ' + str(instance) + '/runtime.previous-*.')


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
