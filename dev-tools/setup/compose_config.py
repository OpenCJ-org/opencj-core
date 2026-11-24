"""Generate an instance-specific Compose project without mounting developer sources."""

from pathlib import Path
from configuration import MYSQL_IMAGE

LOGGING = {'driver': 'local', 'options': {'max-size': '10m', 'max-file': '3'}}


def bind(source, target, *, readonly=True):
    return {'type': 'bind', 'source': str(source), 'target': target,
            'read_only': readonly, 'bind': {'create_host_path': False}}


def service_defaults(image):
    return {'image': image, 'restart': 'unless-stopped', 'logging': LOGGING,
            'security_opt': ['no-new-privileges:true']}


def database_network(settings):
    return settings['database'].get('network', settings['project'] + '_default')


def connection_host(settings):
    if settings['database'].get('transport') == 'ssh':
        return 'db-tunnel'
    return settings['database']['host']


def compose_document(settings, instance):
    """Give gameplay only assets, its runtime account, and its own writable state."""
    database = settings['database']
    server = service_defaults(settings['image'])
    server.update({
        'user': f"{settings['uid']}:{settings['gid']}", 'read_only': True,
        'group_add': sorted({str(Path(settings[key]).stat().st_gid) for key in ('game_dir', 'mod_dir')
                             if Path(settings[key]).stat().st_gid != 0}),
        'cap_drop': ['ALL'], 'pids_limit': 256, 'mem_limit': '3g',
        'tmpfs': ['/tmp:rw,nosuid,nodev,size=64m,mode=1777'],
        'ports': [f"{settings['bind_ip']}:{settings['port']}:28960/{protocol}"
                  for protocol in ('udp', 'tcp')],
        'volumes': [bind(settings['game_dir'], '/game'), bind(settings['mod_dir'], '/mod-assets'),
                    bind(instance / 'runtime', '/runtime', readonly=False),
                    bind(instance / 'server.cfg', '/run/opencj/server.cfg'),
                    bind(instance / 'runtime.json', '/run/opencj/runtime.json')],
        'healthcheck': {'test': ['CMD', 'python3', '/opt/opencj/runtime.py', 'healthcheck'],
                        'interval': '30s', 'start_interval': '5s', 'timeout': '5s', 'start_period': '90s', 'retries': 4},
        'stdin_open': True, 'tty': True,
        'networks': {'default': {'aliases': [settings['project'] + '-game']}},
        'extra_hosts': ['host.docker.internal:host-gateway'],
    })
    document = {'name': settings['project'], 'services': {'server': server}}
    if database.get('network'):
        document['networks'] = {'default': {'external': True, 'name': database['network']}}
    if database['mode'] == 'new':
        db = service_defaults(MYSQL_IMAGE)
        db.update({
            'environment': {'MYSQL_DATABASE': database['name'], 'OPENCJ_GAME_USER': database['user'],
                            'OPENCJ_GAME_PASSWORD_FILE': '/run/secrets/runtime-password',
                            'MYSQL_ROOT_PASSWORD_FILE': '/run/secrets/root-password',
                            'MYSQL_ROOT_HOST': '%'},
            'command': ['--log-bin-trust-function-creators=1'],
            'volumes': [{'type': 'volume', 'source': 'database', 'target': '/var/lib/mysql',
                         'volume': {'nocopy': True}},
                        bind(instance / 'secrets/root-password', '/run/secrets/root-password'),
                        bind(instance / 'secrets/runtime-password', '/run/secrets/runtime-password')],
            'healthcheck': {'test': ['CMD', 'mysqladmin', 'ping', '--silent'],
                            'interval': '5s', 'timeout': '5s', 'retries': 60, 'start_period': '30s'},
        })
        identity = settings.get('linux_accounts', {}).get('database')
        if identity:
            db.update({
                'user': f"{identity['uid']}:{identity['gid']}",
                'read_only': True, 'cap_drop': ['ALL'], 'pids_limit': 256,
                'tmpfs': [
                    '/tmp:rw,nosuid,nodev,size=128m,mode=1777',
                    f"/var/run/mysqld:rw,nosuid,nodev,uid={identity['uid']},gid={identity['gid']},mode=0750",
                ],
            })
        if database['publish_port']:
            db['ports'] = [f"127.0.0.1:{database['publish_port']}:3306"]
        document['services']['db'] = db
        document['volumes'] = {'database': {'external': True, 'name': settings['volume']}}
        server['depends_on'] = {'db': {'condition': 'service_healthy'}}
    if settings['discord']['enabled']:
        add_discord_bridge(document, settings, instance)
    if settings['geoip']['enabled']:
        add_geoip_updater(document, settings, instance)
    if database.get('transport') == 'ssh':
        ssh = database['ssh']
        identity = settings.get('linux_accounts', {}).get('tunnel', {'uid': settings['uid'], 'gid': settings['gid']})
        tunnel = service_defaults(settings['image'])
        tunnel.update({
            'user': f"{identity['uid']}:{identity['gid']}", 'read_only': True,
            'pids_limit': 32, 'mem_limit': '128m',
            'cap_drop': ['ALL'], 'entrypoint': ['/usr/bin/ssh'],
            'command': ['-N', '-T', '-p', str(ssh['port']), '-i', '/run/ssh/key',
                        '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
                        '-o', 'UserKnownHostsFile=/run/ssh/known_hosts',
                        '-o', 'ExitOnForwardFailure=yes', '-o', 'ConnectTimeout=10',
                        '-o', 'ServerAliveInterval=30', '-o', 'ServerAliveCountMax=3',
                        '-L', f"0.0.0.0:3306:{database['host']}:{database['port']}",
                        ssh['user'] + '@' + ssh['host']],
            'volumes': [bind(instance / 'secrets/ssh-key', '/run/ssh/key'),
                        bind(instance / 'secrets/known_hosts', '/run/ssh/known_hosts'),
                        bind(instance / 'secrets/ssh-passwd', '/etc/passwd')],
        })
        document['services']['db-tunnel'] = tunnel
        server['depends_on'] = {'db-tunnel': {'condition': 'service_started'}}
    return document


def add_discord_bridge(document, settings, instance):
    """Chat bridge between the game and one Discord channel through a shared Unix socket.

    The game connects to /tmp/opencj_events_cod4, so both containers mount the same
    socket folder at /tmp. The bridge creates the socket group-writable (umask 007)
    and the game joins the bridge's group; nothing else can reach the socket.
    """
    identity = settings['linux_accounts']['discord']
    server = document['services']['server']
    server['tmpfs'] = []
    server['volumes'].append(bind(instance / 'sockets', '/tmp', readonly=False))
    server['group_add'] = sorted({*server['group_add'], str(identity['gid'])})
    bridge = service_defaults(settings['discord_image'])
    bridge.update({
        'user': f"{identity['uid']}:{identity['gid']}", 'read_only': True,
        'cap_drop': ['ALL'], 'pids_limit': 64, 'mem_limit': '256m',
        'working_dir': '/config',
        'entrypoint': ['sh', '-c', 'umask 007 && exec python /bridge/start.py cod4'],
        'volumes': [bind(instance / 'secrets/discord', '/config'),
                    bind(instance / 'sockets', '/tmp', readonly=False)],
    })
    document['services']['discord'] = bridge


def add_geoip_updater(document, settings, instance):
    """Daily check for the monthly IP-country release, with an account limited to the GeoIP tables."""
    identity = settings['linux_accounts']['geoip']
    updater = service_defaults(settings['geoip_image'])
    updater.update({
        'user': f"{identity['uid']}:{identity['gid']}", 'read_only': True,
        'cap_drop': ['ALL'], 'pids_limit': 64, 'mem_limit': '384m',
        'tmpfs': ['/tmp:rw,nosuid,nodev,size=256m,mode=1777'],
        'environment': {'GEOIP_DB_HOST': 'db', 'GEOIP_DB_PORT': '3306',
                        'GEOIP_DB_NAME': settings['database']['name'],
                        'GEOIP_DB_USER': settings['geoip']['user'],
                        'GEOIP_DB_PASSWORD_FILE': '/run/secrets/geoip-password'},
        'volumes': [bind(instance / 'secrets/geoip-password', '/run/secrets/geoip-password')],
        'depends_on': {'db': {'condition': 'service_healthy'}},
    })
    document['services']['geoip'] = updater
