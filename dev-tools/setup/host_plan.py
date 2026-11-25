"""Create a saved host plan for separate, copied and shared OpenCJ instances, and set them up."""

import argparse
import getpass
import os
from pathlib import Path
import re
import subprocess
import sys

from configuration import ask, ask_int, ask_port, ask_yes_no, choose_port, collect_database, collect_discord
from configuration import collect_downloads, collect_ssh, prompt, REMOTE_DATABASE_ENABLED, validate_port
from operations import operation_lock, read_json, save_json

ROOT = Path(__file__).resolve().parents[2]
INSTANCE_NAME_PATTERN = r'[a-z][a-z0-9-]{0,30}'
LOCAL_DATABASE_CHOICES = ('new', 'migrate', 'restore', 'copy', 'share')
REMOTE_DATABASE_CHOICES = ('owner', 'existing')
DATABASE_CHOICES = LOCAL_DATABASE_CHOICES + (REMOTE_DATABASE_CHOICES if REMOTE_DATABASE_ENABLED else ())
INSTANCE_SETUP_TIMEOUT_SECONDS = 14400


def parse_address(text):
    """A DNS name players connect to, or blank for the IP address."""
    from website import validate_domain
    return validate_domain(text.strip())


def validate_instance_name(name):
    if not re.fullmatch(INSTANCE_NAME_PATTERN, name):
        raise ValueError('use lowercase letters, digits and hyphens, starting with a letter (max 31)')
    return name


def collect_migration():
    local = ask_yes_no('Is the source on this machine?', False)
    result = {
        'transport': 'local' if local else 'ssh',
        'source_root': prompt('Source opencj-core checkout directory'),
        'source_instance': prompt('Source instance directory (or development dev-tools directory)'),
        'intent': ask('Migration intent: rehearsal / cutover', 'rehearsal', choices=('rehearsal', 'cutover')),
        'allowed_player': prompt('Connected player allowed during maintenance (blank requires empty server)'),
    }
    if not local:
        result['ssh'] = collect_ssh()
        result['sudo'] = ask_yes_no('Use sudo for source administration?', result['ssh']['user'] != 'root')
    return result


def collect_instance(index, name, instances, used_ports):
    """All questions for one server; nothing is created yet."""
    print('\n== ' + name + ' ==', flush=True)
    default_port = choose_port(28960 + index)
    while default_port in used_ports:
        default_port = choose_port(default_port + 1)
    settings = {
        'name': name, 'hostname': prompt('Server display name', 'OpenCJ ' + name),
        'port': ask_port('Game port', default_port),
        'address': ask('Address players connect to, for example eu.opencj.org (blank: the IP address)', '',
                       parse=parse_address),
        'bind_ip': prompt('Game bind address', '0.0.0.0'),
        'slots': ask_int('Player slots', 32, 1, 32),
        'public': ask_yes_no('Public access without a join password?', False),
    }
    default = 'migrate' if index == 0 else 'copy' if name == 'acceptance' else 'new'
    if index == 0 and default == 'migrate' and not ask_yes_no('Migrate this server from an existing installation?', True):
        default = 'new'
    choice = ask('Database: ' + ' / '.join(DATABASE_CHOICES), default, choices=DATABASE_CHOICES)
    if choice in ('copy', 'share'):
        if not instances:
            raise ValueError('Place the database owner before instances that copy/share it')
        owners = [item['name'] for item in instances]
        reference = ask('Source instance name', owners[0], choices=owners)
        settings['copy_from' if choice == 'copy' else 'share_with'] = reference
    elif choice in ('migrate', 'restore'):
        settings['database'] = {'mode': 'new', 'publish_port': 0}
        settings['migration'] = collect_migration() if choice == 'migrate' else {
            'transport': 'bundle', 'bundle': prompt('Complete migration bundle directory')}
    elif choice in ('existing', 'owner'):
        print('Enter the existing restricted database connection.', flush=True)
        settings['database'] = collect_database(choice)
    else:
        settings['database'] = {'mode': 'new', 'publish_port': 0}
    if REMOTE_DATABASE_ENABLED and index == 0 and settings.get('database', {}).get('mode') == 'new':
        settings['database']['publish_port'] = ask_port(
            'Loopback database port for future servers in other countries (0 disables)', choose_port(3306),
            allow_disabled=True)
    if choice not in ('migrate', 'restore', 'copy'):
        settings['map'] = prompt('Initial map', 'mp_killhouse')
        if instances:
            owners = [item['name'] for item in instances]
            settings['assets_from'] = ask('Instance providing installed maps/mod assets', owners[0], choices=owners)
        else:
            for kind in ('game', 'mod'):
                settings[kind + '_assets'] = prompt(kind.title() + ' assets directory/archive/HTTPS URL')
                if settings[kind + '_assets'].startswith('https://'):
                    settings[kind + '_sha256'] = prompt(kind.title() + ' SHA-256')
    settings['downloads'] = collect_downloads(name, public=settings['public'])
    settings['discord'] = collect_discord(name)
    from maintenance import collect_database_maintenance
    owns_database = choice in ('new', 'migrate', 'restore', 'copy')
    settings.update(collect_database_maintenance(name, owns_database=owns_database))
    return settings


def collect_website_choice(instances):
    if not ask_yes_no('Run the OpenCJ website on this machine?', False):
        return
    names = [item['name'] for item in instances]
    selected = ask('Website game instance', names[0], choices=names)
    settings = next(item for item in instances if item['name'] == selected)
    from website import collect_website
    settings['website'] = collect_website(settings['port'], game_address=settings.get('address', ''))
    if settings.get('database', {}).get('mode') == 'existing':
        settings['website']['user'] = prompt('Dedicated external read-only website account')
        settings['website']['password'] = getpass.getpass('Website database password: ')
    if settings['website']['domain'] and settings['downloads']['mode'] == 'in-game' and settings['public']:
        if ask_yes_no('Serve this public server\'s map downloads from the website (faster)?', True):
            settings['downloads'] = {'mode': 'website', 'base_url': 'http://' + settings['website']['domain']}


def collect_host_settings(plan):
    from firewall import collect_firewall
    from maintenance import collect_alerts, collect_updates
    from ssh_hardening import collect_ssh_hardening
    print('\n== This machine ==', flush=True)
    plan['security_updates'] = collect_updates()
    plan['firewall'] = collect_firewall()
    plan['ssh_hardening'] = collect_ssh_hardening()
    plan['alerts'] = collect_alerts()


def database_summary(settings):
    if settings.get('copy_from'):
        return 'copy of ' + settings['copy_from']
    if settings.get('share_with'):
        return 'shared with ' + settings['share_with']
    if settings.get('migration'):
        return 'migrated (' + settings['migration'].get('intent', 'bundle') + ')'
    return settings['database']['mode']


def print_summary(plan):
    print('\nSummary', flush=True)
    for settings in plan['instances']:
        extras = []
        if settings.get('backups', {}).get('enabled'):
            offsite = settings['backups'].get('offsite', {})
            extras.append('backups' + (' + off-site' if offsite.get('enabled') else ''))
        if settings.get('pruning', {}).get('enabled'):
            extras.append('prune runs > ' + str(settings['pruning']['months']) + ' months')
        if settings.get('geoip', {}).get('enabled'):
            extras.append('IP-country updates')
        if settings['discord']['enabled']:
            extras.append('Discord')
        if settings.get('website'):
            website = settings['website']
            extras.append('website ' + (' + '.join([website['domain'], *website.get('aliases', [])])
                                        if website['domain'] else 'local'))
        if settings.get('address'):
            extras.append('address ' + settings['address'])
        print(f"  {settings['name']:14} port {settings['port']:<5} "
              f"{'public' if settings['public'] else 'private':7} database: {database_summary(settings):22} "
              f"downloads: {settings['downloads']['mode']:8} {', '.join(extras)}", flush=True)
    updates = plan['security_updates']
    print('  Security updates: ' + ('daily ' + updates['time'] + (', reboot when needed'
                                    if updates.get('reboot') else '') if updates['enabled'] else 'off'), flush=True)
    print('  Firewall: ' + ('on' if plan['firewall']['enabled'] else 'off')
          + '; alerts: ' + ('Discord webhook' if plan['alerts']['discord_webhook'] else 'log only'), flush=True)
    hardening = plan.get('ssh_hardening', {})
    if hardening:
        print('  SSH: ' + ('key-only' if hardening['key_only'] else 'passwords allowed')
              + (', fail2ban' if hardening['fail2ban'] else '')
              + (', move to port ' + str(hardening['new_port']) if hardening.get('new_port') else ''), flush=True)


def collect_plan():
    """Ask for topology before creating any resource, then confirm the summary."""
    names = ask('Servers to create (comma-separated)', 'main-eu,acceptance,map-test',
                parse=lambda text: [validate_instance_name(name.strip()) for name in text.split(',')])
    if len(names) != len(set(names)):
        raise ValueError('Instance names must be unique')
    instances = []
    used_ports = set()
    for index, name in enumerate(names):
        settings = collect_instance(index, name, instances, used_ports)
        used_ports.add(settings['port'])
        instances.append(settings)
    collect_website_choice(instances)
    plan = {'instances': instances}
    collect_host_settings(plan)
    import dns_guide
    if dns_guide.wanted_names(plan):
        dns_guide.ensure_public_ipv4(plan)
    print_summary(plan)
    # Shown now, so the records can spread while the servers are installed.
    dns_guide.print_records(plan)
    if not ask_yes_no('Install with these choices?', True):
        raise SystemExit('Nothing was installed. Run setup again to choose differently.')
    return plan


def validate_plan(plan):
    """Reject ambiguous ownership and dependency cycles before the first installation."""
    previous = set()
    ports = set()
    for settings in plan['instances']:
        name = validate_instance_name(settings['name'])
        if name in previous:
            raise ValueError('Instance names must be unique')
        port = settings.get('port', 28960)
        validate_port(port)
        if port in ports:
            raise ValueError('Each instance needs a distinct game port')
        ports.add(port)
        extra_ports = [settings.get('database', {}).get('publish_port', 0)]
        if settings.get('website'):
            extra_ports.append(settings['website'].get('port', 8090))
        for extra_port in extra_ports:
            validate_port(extra_port, allow_disabled=True)
            if extra_port:
                if extra_port in ports:
                    raise ValueError('Game, website and published database ports must be distinct')
                ports.add(extra_port)
        for dependency in ('copy_from', 'share_with', 'assets_from'):
            if dependency in settings and settings[dependency] not in previous:
                raise ValueError('Place referenced instances before their dependents')
        database = settings.get('database', {})
        if not REMOTE_DATABASE_ENABLED and (database.get('mode') in REMOTE_DATABASE_CHOICES
                                            or database.get('publish_port')):
            raise ValueError('Sharing a database with another machine is switched off until it has been tested'
                             ' (REMOTE_DATABASE_ENABLED in dev-tools/setup/configuration.py)')
        settings['address'] = parse_address(settings.get('address', ''))
        previous.add(name)
    if not previous:
        raise ValueError('Choose at least one game instance')
    from configuration import check_discord_channels
    check_discord_channels(plan['instances'])
    if sum(1 for settings in plan['instances'] if settings.get('website', {}).get('domain')) > 1:
        raise ValueError('Only one website with a domain can use ports 80/443 on this machine')
    from maintenance import validate_updates, validate_webhook
    plan['security_updates'] = validate_updates(plan.get('security_updates', {}))
    plan.setdefault('firewall', {'enabled': False})
    plan.setdefault('alerts', {'discord_webhook': ''})
    validate_webhook(plan['alerts']['discord_webhook'])
    from ssh_hardening import validate_ssh_hardening
    plan['ssh_hardening'] = validate_ssh_hardening(plan.get('ssh_hardening', {}))


def resolve_settings(host, settings):
    """Resolve dependencies only after their installation has passed its readiness checks."""
    result = dict(settings)
    reference = result.pop('copy_from', None)
    if reference:
        result['database'] = {'mode': 'new', 'publish_port': 0}
        result['copy_source'] = reference
        result['migration'] = {
            'transport': 'local', 'source_root': str(ROOT), 'source_instance': str(host / reference),
            'intent': 'rehearsal', 'shared_assets': True,
        }
    reference = result.pop('share_with', None)
    if reference:
        result['database'] = {'mode': 'instance', 'instance_dir': str(host / reference)}
    reference = result.pop('assets_from', None)
    if reference:
        source = read_json(host / reference / 'installation.json')
        if source.get('state') != 'ready' or source.get('instance_dir') != str(host / reference):
            raise ValueError('Asset source is not a ready installation')
        result['game_assets'] = source['game_dir']
        result['mod_assets'] = source['mod_dir']
    return result


def apply_host_configuration(host, plan, record):
    """Firewall, updates and host-wide timers: re-applied on every run so they follow the plan."""
    from firewall import configure_firewall
    from maintenance import configure_host_jobs, configure_updates, install_command_link
    from ssh_hardening import apply_ssh_hardening
    install_command_link()
    # Allow every planned port before servers start, so a new server is reachable at once.
    configure_firewall(plan, plan['instances'])

    def open_firewall(extra_ssh_ports=()):
        configure_firewall(plan, plan['instances'], extra_ssh_ports=extra_ssh_ports)

    try:
        apply_ssh_hardening(plan, open_firewall)
    finally:
        save_json(record, plan)
    if not plan.get('updates_configured'):
        configure_updates(plan.get('security_updates', {}))
        plan['updates_configured'] = True
        save_json(record, plan)
    configure_host_jobs(host)


def install_instances(host, plan, record):
    for raw_settings in plan['instances']:
        name = raw_settings['name']
        instance = host / name
        arguments = [sys.executable, '-B', str(ROOT / 'dev-tools/setup/install.py'),
                     '--instance-dir', str(instance)]
        answers = None
        if not (instance / 'installation.json').exists():
            answers = host / ('.' + name + '-answers.json')
            save_json(answers, resolve_settings(host, raw_settings))
            arguments.extend(['--config', str(answers)])
        print('Setting up ' + name + '...', flush=True)
        try:
            result = subprocess.run(arguments, timeout=INSTANCE_SETUP_TIMEOUT_SECONDS)
            if result.returncode:
                raise RuntimeError('Instance setup stopped: ' + name + '; rerun the same host setup command')
        finally:
            if answers:
                answers.unlink(missing_ok=True)
        if name not in plan['completed']:
            plan['completed'].append(name)
            save_json(record, plan)


def add_server(host, plan, record):
    """Append one server to an existing host plan; existing servers are not touched."""
    names = [item['name'] for item in plan['instances']]
    name = ask('Name of the new server', parse=validate_instance_name)
    if name in names:
        raise ValueError('A server with that name already exists')
    used_ports = {item['port'] for item in plan['instances']}
    settings = collect_instance(len(plan['instances']), name, plan['instances'], used_ports)
    candidate = dict(plan)
    candidate['instances'] = [*plan['instances'], settings]
    validate_plan(candidate)
    print_summary({**candidate, 'instances': [settings]})
    import dns_guide
    if settings.get('address'):
        dns_guide.ensure_public_ipv4(plan)
        dns_guide.print_records({**plan, 'instances': [settings]})
    if not ask_yes_no('Add this server?', True):
        raise SystemExit('Nothing was changed.')
    plan['instances'].append(settings)
    save_json(record, plan)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', nargs='?', choices=['add-server'])
    parser.add_argument('--host-dir', type=Path, default=Path('/srv/opencj'))
    parser.add_argument('--plan', type=Path, help='Private JSON host plan for unattended setup')
    args = parser.parse_args()
    os.umask(0o077)
    if os.geteuid() != 0:
        parser.error('Run with sudo: setup creates dedicated Linux service users')
    host = args.host_dir.expanduser().resolve()
    host.mkdir(mode=0o700, parents=True, exist_ok=True)
    with operation_lock(host / '.host-setup.lock'):
        record = host / 'host-setup.json'
        if record.exists():
            if args.plan:
                raise ValueError('Existing host plan preserved; rerun without --plan')
            plan = read_json(record)
            if plan.get('host_dir') != str(host):
                raise ValueError('Host plan belongs to another directory')
            if args.command == 'add-server':
                add_server(host, plan, record)
        else:
            if args.command == 'add-server':
                raise ValueError('No servers are installed yet; run setup without add-server first')
            plan = read_json(args.plan) if args.plan else collect_plan()
            validate_plan(plan)
            plan['host_dir'] = str(host)
            plan['completed'] = []
            save_json(record, plan)
        apply_host_configuration(host, plan, record)
        # Wait for DNS only while a website still has to be installed; reruns of a finished
        # installation should not stop on a DNS question.
        if any(settings.get('website', {}).get('domain') and settings['name'] not in plan['completed']
               for settings in plan['instances']):
            import dns_guide
            dns_guide.wait_for_website_dns(plan)
        install_instances(host, plan, record)
        print('All selected instances are ready. Private connection details are in their installation directories.')
        print('Next: sudo opencj status, then sudo opencj alerts (it also prints how another machine can'
              ' report an outage of this one). Daily operation: docs/operations/server-administration.md')


if __name__ == '__main__':
    main()
