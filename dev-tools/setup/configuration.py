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


DOWNLOAD_MODES = ('website', 'in-game', 'off')
DISCORD_SNOWFLAKE_PATTERN = r'[0-9]{15,22}'
DISCORD_TOKEN_MAX_CHARACTERS = 200
# The bridge accepts at most this many users that players may mention.
DISCORD_MENTION_USERS_MAX = 25
# Servers on another machine using a database here (through an SSH tunnel). The code
# stays, but the prompts do not offer it until it has been tested between two real
# machines; see docs/setup/server.md.
REMOTE_DATABASE_ENABLED = False
# Official Discord how-to pages, shown next to the questions that need their answers.
DISCORD_BOT_GUIDE = 'https://docs.discord.com/developers/quick-start/getting-started'
DISCORD_APPLICATIONS_URL = 'https://discord.com/developers/applications'
DISCORD_MESSAGE_CONTENT_GUIDE = 'https://docs.discord.com/developers/events/gateway#message-content-intent'
DISCORD_ID_GUIDE = 'https://support.discord.com/hc/en-us/articles/206346498'
DISCORD_WEBHOOK_GUIDE = 'https://support.discord.com/hc/en-us/articles/228383668'


def ask(label, default='', *, parse=None, choices=None):
    """Ask until the answer is valid, so one typo does not discard all earlier answers.

    parse converts the text and raises ValueError for an invalid answer; choices
    limits the answer to fixed words. End of input still stops setup (EOFError).
    """
    while True:
        answer = input(f'{label} [{default}]: ').strip() or str(default)
        if choices and answer not in choices:
            print('Choose one of: ' + ', '.join(choices), flush=True)
            continue
        if parse is None:
            return answer
        try:
            return parse(answer)
        except ValueError as error:
            print('Invalid answer: ' + str(error), flush=True)


def prompt(label, default=''):
    return ask(label, default)


def ask_yes_no(label, default):
    answer = ask(label + ' yes/no', 'yes' if default else 'no', choices=('yes', 'no'))
    return answer == 'yes'


def ask_int(label, default, minimum, maximum):
    def parse(text):
        value = int(text)
        if not minimum <= value <= maximum:
            raise ValueError(f'use a number from {minimum} to {maximum}')
        return value
    return ask(label, default, parse=parse)


def ask_port(label, default, *, allow_disabled=False):
    return ask_int(label, default, 0 if allow_disabled else 1, 65535)


def is_main_instance(name):
    """Main/production servers get production defaults (backups, Discord, GeoIP)."""
    return name == 'main' or name.startswith('main-')


def ask_on_demand(name, current=None):
    """Test servers (acceptance, map-test) are normally off and started only when needed."""
    default = not is_main_instance(name) if current is None else current
    return ask_yes_no('Keep ' + name + ' off until you start it (sudo opencj start ' + name + ')?', default)


def validate_on_demand(settings):
    """An on-demand server stops completely, its own database included.

    The website reads its server's database, so that server must always run.
    """
    on_demand = settings.get('on_demand', False)
    if type(on_demand) is not bool:
        raise ValueError('on_demand must be a Boolean')
    if on_demand and settings.get('website'):
        raise ValueError(settings['name'] + ' runs the website, so it cannot be switched off on demand')
    return on_demand


def check_on_demand(instances):
    """Refuse on-demand servers that other servers need running: database shared with or copied by another."""
    needed = {}
    for settings in instances:
        for dependency, reason in (('share_with', 'shares its database'), ('copy_from', 'copies its data'),
                                   ('copy_source', 'copies its data')):
            if settings.get(dependency):
                needed.setdefault(settings[dependency], settings['name'] + ' ' + reason)
    for settings in instances:
        validate_on_demand(settings)
        if settings.get('on_demand') and settings['name'] in needed:
            raise ValueError(settings['name'] + ' cannot be switched off on demand: '
                             + needed[settings['name']])


def collect_downloads(name, *, public, website_url=''):
    """Choose how players obtain missing maps on this server.

    website: fast HTTP downloads of pool maps from the OpenCJ website.
    in-game: the game sends files itself (slow), only to players who can join,
             so a password-protected server keeps its test maps private.
    off: players must already have the maps.
    """
    default = 'website' if public and website_url else 'in-game'
    mode = ask('Map downloads for ' + name + ': ' + ' / '.join(DOWNLOAD_MODES), default,
               choices=DOWNLOAD_MODES)
    result = {'mode': mode}
    if mode == 'website':
        result['base_url'] = ask('Website address for map downloads (http://, CoD4 clients cannot use https)',
                                 website_url or 'http://', parse=validate_download_url)
    return result


def collect_discord(name):
    """Optional chat bridge between this server and one Discord channel."""
    if not ask_yes_no('Connect ' + name + ' to Discord (chat bridge)?', is_main_instance(name)):
        return {'enabled': False}
    print('\nThe chat bridge needs a Discord bot (one bot can serve every server):\n'
          '  1. Create an application and its bot at ' + DISCORD_APPLICATIONS_URL + '\n'
          '     (step by step: ' + DISCORD_BOT_GUIDE + ').\n'
          '  2. On the Bot page, switch on "Message Content Intent": the bridge reads chat messages\n'
          '     (' + DISCORD_MESSAGE_CONTENT_GUIDE + ').\n'
          '  3. Invite the bot to your Discord server with permission to view the channel and send messages.\n'
          '  4. In Discord: User Settings > Advanced > Developer Mode on; then right-click your server and the\n'
          '     chat channel > Copy ID (' + DISCORD_ID_GUIDE + ').\n'
          '  5. Bot page > Reset Token, and copy the token (it is shown once).', flush=True)
    result = {
        'enabled': True,
        'guild_id': ask('Discord server (guild) ID', parse=validate_discord_id),
        'channel_id': ask('Discord channel ID for server chat', parse=validate_discord_id),
        'token': validate_discord_token(getpass.getpass('Discord bot token (hidden): ').strip()),
    }
    print('Players can never ping @everyone, @here or roles. You may allow pings of a few people, for example'
          ' the admins (right-click a user > Copy User ID).', flush=True)
    result['mention_user_ids'] = ask('Discord user IDs players may mention, comma-separated (blank for none)',
                                     '', parse=parse_mention_user_ids)
    return result


def parse_mention_user_ids(text):
    """Comma-separated Discord user IDs; duplicates dropped, at most DISCORD_MENTION_USERS_MAX."""
    if isinstance(text, list):
        values = [str(value) for value in text]
    else:
        values = [value.strip() for value in text.split(',') if value.strip()]
    result = []
    for value in values:
        validate_discord_id(value)
        if value not in result:
            result.append(value)
    if len(result) > DISCORD_MENTION_USERS_MAX:
        raise ValueError('at most ' + str(DISCORD_MENTION_USERS_MAX) + ' users')
    return result


def validate_download_url(url):
    if not re.fullmatch(r'http://[A-Za-z0-9][A-Za-z0-9.-]{0,252}(:[0-9]{1,5})?', url):
        raise ValueError('use http://hostname without a path; the game appends usermaps/<map>/<file>')
    return url


def validate_discord_id(value):
    if not re.fullmatch(DISCORD_SNOWFLAKE_PATTERN, value):
        raise ValueError('Discord IDs are 15-22 digits (enable Developer Mode, then Copy ID)')
    return value


def validate_discord_token(token):
    # The bridge reads key=value lines, so a token must be one line without spaces.
    if not token or len(token) > DISCORD_TOKEN_MAX_CHARACTERS or not re.fullmatch(r'[A-Za-z0-9._-]+', token):
        raise ValueError('Invalid Discord bot token')
    return token


def validate_downloads(downloads):
    if not isinstance(downloads, dict) or downloads.get('mode') not in DOWNLOAD_MODES:
        raise ValueError('downloads.mode must be one of: ' + ', '.join(DOWNLOAD_MODES))
    result = {'mode': downloads['mode']}
    if result['mode'] == 'website':
        result['base_url'] = validate_download_url(downloads.get('base_url', ''))
    return result


def validate_discord(discord):
    if not isinstance(discord, dict) or type(discord.get('enabled')) is not bool:
        raise ValueError('discord.enabled must be a Boolean')
    if not discord['enabled']:
        return {'enabled': False}
    return {'enabled': True,
            'guild_id': validate_discord_id(str(discord.get('guild_id', ''))),
            'channel_id': validate_discord_id(str(discord.get('channel_id', ''))),
            'token': validate_discord_token(str(discord.get('token', ''))),
            'mention_user_ids': parse_mention_user_ids(discord.get('mention_user_ids', []))}


def check_discord_channels(instances):
    """Each bridge relays one server's chat; two servers in one channel would mix their chat.

    The bridge itself only reads its own server's events and only messages from its
    configured channel, so a distinct channel per server keeps them apart.
    """
    owners = {}
    for settings in instances:
        discord = settings.get('discord') or {}
        if not discord.get('enabled'):
            continue
        channel = str(discord['channel_id'])
        if channel in owners:
            raise ValueError('Servers ' + owners[channel] + ' and ' + settings['name'] + ' would share Discord channel '
                             + channel + '; give each bridge its own channel')
        owners[channel] = settings['name']


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


def collect_database(mode=None):
    """Keep existing-database credentials separate from new local administration."""
    choices = ('new', 'instance', 'owner', 'existing') if REMOTE_DATABASE_ENABLED else ('new', 'instance')
    if mode is None:
        mode = ask('Database: ' + ' / '.join(choices), 'new', choices=choices)
    if mode not in choices:
        raise ValueError('Sharing a database with another machine is switched off until it has been tested')
    if mode == 'new':
        publish_port = 0
        if REMOTE_DATABASE_ENABLED:
            publish_port = ask_port('Local database port (SSH sharing; 0 disables)', choose_port(3306),
                                    allow_disabled=True)
        return {'mode': 'new', 'name': 'openCJ_cod4', 'publish_port': publish_port}
    if mode == 'instance':
        return {'mode': 'instance', 'instance_dir': prompt('Existing OpenCJ instance directory')}
    if mode == 'owner':
        ssh = collect_ssh()
        return {'mode': 'owner', 'ssh': ssh, 'owner_remote': {
            'root': prompt('Database owner opencj-core checkout'),
            'instance': prompt('Database owner installation directory'),
            'sudo': ask_yes_no('Use sudo for source administration?', ssh['user'] != 'root'),
        }}
    if mode != 'existing':
        raise ValueError('Database choice must be new, instance, owner, or existing')
    database = {'mode': 'existing', 'transport': ask('Database transport: ssh / private', 'ssh',
                                                     choices=('ssh', 'private'))}
    database['host'] = prompt('Database hostname as reached by that connection', '127.0.0.1')
    database['port'] = ask_port('Database port', 3306)
    database['name'] = prompt('Existing database name (must end in 4)', 'openCJ_cod4')
    database['user'] = prompt('Restricted gameplay database user', 'opencj')
    database['password'] = getpass.getpass('Gameplay database password (hidden): ')
    if database['transport'] == 'ssh':
        database['ssh'] = {
            'host': prompt('SSH hostname'), 'port': ask_port('SSH port', 22),
            'user': prompt('SSH user'), 'key': prompt('SSH private-key file'),
            'known_hosts': prompt('Verified SSH known_hosts file'),
        }
    return database


def collect_ssh():
    return {
        'host': prompt('Source SSH hostname'), 'port': ask_port('Source SSH port', 22),
        'user': prompt('Source SSH user'), 'key': prompt('SSH private-key file'),
        'known_hosts': prompt('Verified SSH known_hosts file'),
    }


def collect_configuration(instance_dir):
    name = prompt('Instance name', instance_dir.name)
    mode = ask('Installation: new / migrate / restore', 'new', choices=('new', 'migrate', 'restore'))
    result = {
        'name': name, 'hostname': prompt('Server display name', f'OpenCJ {name}'),
        'port': ask_port('Game port', choose_port(28960)),
        'bind_ip': prompt('Game bind address', '0.0.0.0'),
        'slots': ask_int('Player slots', 32, 1, 32),
        'public': ask_yes_no('List publicly without a join password?', False),
    }
    result['downloads'] = collect_downloads(name, public=result['public'])
    result['discord'] = collect_discord(name)
    if mode == 'new':
        result['map'] = prompt('Initial installed map', 'mp_killhouse')
        for kind in ('game', 'mod'):
            result[kind + '_assets'] = prompt(kind.title() + ' assets directory/archive/HTTPS URL')
            if result[kind + '_assets'].startswith('https://'):
                result[kind + '_sha256'] = prompt(kind.title() + ' archive SHA-256')
        result['database'] = collect_database()
    elif mode in ('migrate', 'restore'):
        result['database'] = {'mode': 'new', 'publish_port': 0}
        if mode == 'restore':
            result['migration'] = {'transport': 'bundle', 'bundle': prompt('Complete migration bundle directory')}
        else:
            local = ask_yes_no('Is the source on this machine?', False)
            migration = {
                'transport': 'local' if local else 'ssh',
                'source_root': prompt('Source opencj-core checkout directory'),
                'source_instance': prompt('Source installation directory (or development dev-tools directory)'),
                'intent': ask('Migration: rehearsal (resume source) / cutover (leave source stopped)', 'rehearsal',
                              choices=('rehearsal', 'cutover')),
                'allowed_player': prompt('Only this connected player may be interrupted (blank requires empty server)'),
            }
            if not local:
                migration['ssh'] = collect_ssh()
                migration['sudo'] = ask_yes_no('Use sudo for source administration?',
                                               migration['ssh']['user'] != 'root')
            result['migration'] = migration
    if ask_yes_no('Run the OpenCJ website?', False):
        from website import collect_website
        result['website'] = collect_website(result['port'])
        if result['database']['mode'] == 'existing':
            result['website']['user'] = prompt('Existing dedicated read-only website database user')
            result['website']['password'] = getpass.getpass('Website database password (hidden): ')
    from maintenance import collect_database_maintenance
    result.update(collect_database_maintenance(name, owns_database=result['database']['mode'] == 'new'))
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


def validate_ssh(ssh):
    validate_host(ssh['host'])
    validate_port(ssh['port'])
    if not re.fullmatch(r'[a-z_][a-z0-9_-]*', ssh['user']):
        raise ValueError('Invalid SSH user')
    for key in ('key', 'known_hosts'):
        path = Path(ssh[key]).expanduser().resolve()
        if not path.is_file():
            raise ValueError(f'Missing SSH {key} file')
        ssh[key] = str(path)


def validate_migration(migration, project):
    transport = migration.get('transport')
    if transport == 'bundle':
        path = Path(migration['bundle']).expanduser().resolve()
        if not (path / 'manifest.json').is_file():
            raise ValueError('Migration bundle manifest is missing')
        migration['bundle'] = str(path)
        return
    if transport not in ('local', 'ssh') or migration.get('intent') not in ('rehearsal', 'cutover'):
        raise ValueError('Invalid source transport or migration intent')
    for key in ('source_root', 'source_instance'):
        value = migration[key]
        if not isinstance(value, str) or not value.startswith('/') or any(char in value for char in '\n\r\x00'):
            raise ValueError('Source paths must be absolute paths without control characters')
    migration['source_bundle'] = migration['source_root'] + '/dev-tools/local/transfers/' + project
    if transport == 'ssh':
        validate_ssh(migration['ssh'])


def resolve_database(database):
    """Resolve shared local instances to their runtime account; never copy their admin secret."""
    mode = database['mode']
    if mode == 'owner':
        database = dict(database)
        database.update(name='openCJ_cod4', host='127.0.0.1', port=3306,
                        user='pending', password='pending', transport='ssh')
        for key in ('root', 'instance'):
            path = database['owner_remote'][key]
            if not isinstance(path, str) or not path.startswith('/') or any(char in path for char in '\n\r\x00'):
                raise ValueError('Remote owner paths must be absolute')
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
        database.update(mode='existing', transport='instance', network=previous['project'] + '_default',
                        owner_instance=str(source))
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
            validate_ssh(database['ssh'])
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
    from website import validate_domain
    # The DNS name players connect to; blank means the machine's IP address.
    result['address'] = validate_domain(result.get('address', ''))
    result.setdefault('slots', 32)
    if type(result['slots']) is not int or not 1 <= result['slots'] <= 32:
        raise ValueError('This release supports 1–32 player slots')
    result.setdefault('public', False)
    if type(result['public']) is not bool:
        raise ValueError('public must be a Boolean')
    result['on_demand'] = validate_on_demand(result)
    result.setdefault('map', 'mp_killhouse')
    if not re.fullmatch(r'[a-z0-9_]+', result['map']):
        raise ValueError('Invalid starting map')
    for kind in ('game', 'mod'):
        if not result.get('migration') and not isinstance(result.get(f'{kind}_assets'), str):
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
    if result['database']['mode'] in ('new', 'owner') or result['database'].get('owner_instance'):
        result['database']['user'] = 'game_' + secrets.token_hex(8)
        result['database']['password'] = secrets.token_hex(24)
    if result.get('migration'):
        if result['database']['mode'] != 'new':
            raise ValueError('Restore requires a new independent database')
        validate_migration(result['migration'], result['project'])
        if result['migration'].get('intent') == 'rehearsal' and result['public']:
            raise ValueError('Rehearsals must remain private')
    if result.get('website'):
        from website import validate_website
        result['website'] = validate_website(result['website'], result['database'])
    result['downloads'] = validate_downloads(result.get('downloads', {'mode': 'in-game'}))
    result['discord'] = validate_discord(result.get('discord', {'enabled': False}))
    from maintenance import backup_policy, geoip_policy, prune_policy
    result['backups'] = backup_policy(result)
    result['pruning'] = prune_policy(result)
    result['geoip'] = geoip_policy(result)
    if result['geoip']['enabled']:
        # The GeoIP provisioning helper accepts only geoip_* account names.
        result['geoip']['user'] = 'geoip_' + secrets.token_hex(6)
    result['uid'] = os.getuid() or 10000
    result['gid'] = os.getgid() or 10000
    result['join_password'] = '' if result['public'] else secrets.token_hex(12)
    result['rcon_password'] = secrets.token_hex(24)
    return result
