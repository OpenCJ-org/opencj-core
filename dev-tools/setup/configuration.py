"""Collect and validate one independent OpenCJ installation's settings."""

import getpass
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import socket

RELEASE = 'beta-0.1.0'
MYSQL_IMAGE = 'mysql:8.0@sha256:7dcddc01f13bab2f15cde676d44d01f61fc9f99fe7785e86196dfc07d358ae2b'


def prompt(label, default=''):
    answer = input(f'{label} [{default}]: ').strip()
    return answer or str(default)


def choose_port(first):
    """Suggest an unused TCP/UDP port without modifying firewall or unrelated services."""
    for port in range(first, min(first + 1000, 65536)):
        try:
            with socket.socket() as tcp, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
                tcp.bind(('0.0.0.0', port))
                udp.bind(('0.0.0.0', port))
                return port
        except OSError:
            continue
    raise ValueError('No free suggested port; specify a port explicitly')


def collect_database():
    """Keep existing-database credentials separate from new local administration."""
    mode = prompt('Database: new / instance / existing', 'new')
    if mode == 'new':
        return {'mode': 'new', 'name': 'openCJ_cod4',
                'publish_port': int(prompt('Local database port (SSH sharing; 0 disables)', choose_port(3306)))}
    if mode == 'instance':
        return {'mode': 'instance', 'instance_dir': prompt('Existing OpenCJ instance directory')}
    if mode != 'existing':
        raise ValueError('Database choice must be new, instance, or existing')
    database = {'mode': 'existing', 'transport': prompt('Database transport: ssh / private', 'ssh')}
    database['host'] = prompt('Database hostname as reached by that connection', '127.0.0.1')
    database['port'] = int(prompt('Database port', 3306))
    database['name'] = prompt('Existing database name (must end in 4)', 'openCJ_cod4')
    database['user'] = prompt('Restricted gameplay database user', 'opencj')
    database['password'] = getpass.getpass('Gameplay database password (hidden): ')
    if database['transport'] == 'ssh':
        database['ssh'] = {
            'host': prompt('SSH hostname'), 'port': int(prompt('SSH port', 22)),
            'user': prompt('SSH user'), 'key': prompt('SSH private-key file'),
            'known_hosts': prompt('Verified SSH known_hosts file'),
        }
    return database


def collect_configuration(instance_dir):
    name = prompt('Instance name', instance_dir.name)
    public = prompt('List publicly and allow access without a join password? yes/no', 'no') == 'yes'
    result = {
        'name': name, 'hostname': prompt('Server display name', f'OpenCJ {name}'),
        'port': int(prompt('Game port', choose_port(28960))),
        'bind_ip': prompt('Game bind address', '0.0.0.0'),
        'slots': int(prompt('Player slots', 32)), 'public': public,
        'map': prompt('Initial installed map', 'mp_killhouse'),
        'game_assets': prompt('Licensed CoD4 assets directory/archive/HTTPS URL'),
        'mod_assets': prompt('Matching compiled OpenCJ assets directory/archive/HTTPS URL'),
        'database': collect_database(),
    }
    for kind in ('game', 'mod'):
        if result[f'{kind}_assets'].startswith('https://'):
            result[f'{kind}_sha256'] = prompt(f'{kind.title()} archive SHA-256')
    if prompt('Run the OpenCJ website on this machine? yes/no', 'no') == 'yes':
        result['website_compose'] = prompt('Website project Compose file (from its README)')
    return result


def safe_cvar(value):
    value = str(value)
    if not value or len(value) > 250 or any(char in value for char in '\r\n\x00"\\;'):
        raise ValueError('A server setting is empty, too long, or contains unsafe config characters')
    return value


def validate_host(host):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]{0,252}', host):
        raise ValueError('Use a DNS hostname or IPv4 address')
    return host


def validate_port(port, *, allow_disabled=False):
    minimum = 0 if allow_disabled else 1
    if type(port) is not int or not minimum <= port <= 65535:
        raise ValueError('Invalid TCP/UDP port')


def resolve_database(database):
    """Resolve shared local instances to their runtime account; never copy their admin secret."""
    mode = database['mode']
    if mode == 'instance':
        source = Path(database['instance_dir']).expanduser().resolve()
        previous = json.loads((source / 'installation.json').read_text())
        if previous.get('instance_dir') != str(source):
            raise ValueError('Shared database record belongs to another directory')
        if previous.get('release') != RELEASE or previous.get('state') != 'ready':
            raise ValueError('Shared instance must be ready on the same release')
        prior_database = previous['database']
        if prior_database['mode'] != 'new':
            raise ValueError('Select the instance that owns the local database')
        database = {key: prior_database[key] for key in ('name', 'user', 'password', 'host', 'port')}
        database.update(mode='existing', transport='instance', network=previous['project'] + '_default')
    if mode == 'new':
        database = dict(database)
        database.setdefault('name', 'openCJ_cod4')
        database.update(user='opencj', password=secrets.token_hex(24), host='db', port=3306)
        database.setdefault('publish_port', 0)
        validate_port(database['publish_port'], allow_disabled=True)
    if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]{0,62}4', database['name']):
        raise ValueError('Database names must be SQL identifiers ending in 4 (the CoD4 suffix)')
    validate_host(database['host'])
    validate_port(database['port'])
    safe_cvar(database['user'])
    safe_cvar(database['password'])
    if database['mode'] != 'new':
        if database.get('transport') not in ('ssh', 'private', 'instance'):
            raise ValueError('Choose an SSH tunnel or an already-secured private database network')
        if database['transport'] == 'ssh':
            ssh = database['ssh']
            validate_host(ssh['host'])
            validate_port(ssh['port'])
            if not re.fullmatch(r'[a-z_][a-z0-9_-]*', ssh['user']):
                raise ValueError('Invalid SSH user')
            for key in ('key', 'known_hosts'):
                path = Path(ssh[key]).expanduser().resolve()
                if not path.is_file():
                    raise ValueError(f'Missing SSH {key} file')
                ssh[key] = str(path)
    return database


def validate_configuration(settings):
    """Validate all operator choices before creating resources or downloading assets."""
    result = dict(settings)
    if not re.fullmatch(r'[a-z][a-z0-9-]{0,30}', result['name']):
        raise ValueError('Instance name must use lowercase letters, digits and hyphens')
    result.setdefault('hostname', 'OpenCJ ' + result['name'])
    safe_cvar(result['hostname'])
    result.setdefault('bind_ip', '0.0.0.0')
    ipaddress.IPv4Address(result['bind_ip'])
    result.setdefault('port', 28960)
    validate_port(result['port'])
    if result['port'] < 1024:
        raise ValueError('Game port must be at least 1024')
    result.setdefault('slots', 32)
    if type(result['slots']) is not int or not 1 <= result['slots'] <= 32:
        raise ValueError('This release supports 1–32 player slots')
    result.setdefault('public', False)
    if type(result['public']) is not bool:
        raise ValueError('public must be a Boolean')
    result.setdefault('map', 'mp_killhouse')
    if not re.fullmatch(r'[a-z0-9_]+', result['map']):
        raise ValueError('Invalid starting map')
    for kind in ('game', 'mod'):
        if not isinstance(result.get(f'{kind}_assets'), str):
            raise ValueError(f'Supply {kind} assets')
    result['database'] = resolve_database(result.get('database', {'mode': 'new'}))
    if result.get('website_compose'):
        website = Path(result['website_compose']).expanduser().resolve()
        if not website.is_file():
            raise ValueError('Website Compose project is not supplied yet; choose no or provide its file')
        result['website_compose'] = str(website)
    result['release'] = RELEASE
    result['project'] = 'opencj-' + result['name'] + '-' + secrets.token_hex(4)
    result['volume'] = result['project'] + '-database'
    result['uid'] = os.getuid() or 10000
    result['gid'] = os.getgid() or 10000
    result['join_password'] = '' if result['public'] else secrets.token_hex(12)
    result['rcon_password'] = secrets.token_hex(24)
    return result
