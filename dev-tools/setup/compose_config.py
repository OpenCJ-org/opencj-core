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
        'group_add': sorted({str(Path(settings[key]).stat().st_gid) for key in ('game_dir', 'mod_dir')}),
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
        'extra_hosts': ['host.docker.internal:host-gateway'],
    })
    document = {'name': settings['project'], 'services': {'server': server}}
    if database.get('network'):
        document['networks'] = {'default': {'external': True, 'name': database['network']}}
    if database['mode'] == 'new':
        db = service_defaults(MYSQL_IMAGE)
        db.update({
            'environment': {'MYSQL_DATABASE': database['name'], 'MYSQL_USER': database['user'],
                            'MYSQL_PASSWORD_FILE': '/run/secrets/runtime-password',
                            'MYSQL_ROOT_PASSWORD_FILE': '/run/secrets/root-password',
                            'MYSQL_ROOT_HOST': '%'},
            'command': ['--log-bin-trust-function-creators=1'],
            'volumes': ['database:/var/lib/mysql',
                        bind(instance / 'secrets/root-password', '/run/secrets/root-password'),
                        bind(instance / 'secrets/runtime-password', '/run/secrets/runtime-password')],
            'healthcheck': {'test': ['CMD', 'mysqladmin', 'ping', '--silent'],
                            'interval': '5s', 'timeout': '5s', 'retries': 60, 'start_period': '30s'},
        })
        if database['publish_port']:
            db['ports'] = [f"127.0.0.1:{database['publish_port']}:3306"]
        document['services']['db'] = db
        document['volumes'] = {'database': {'external': True, 'name': settings['volume']}}
        server['depends_on'] = {'db': {'condition': 'service_healthy'}}
    if database.get('transport') == 'ssh':
        ssh = database['ssh']
        tunnel = service_defaults(settings['image'])
        tunnel.update({
            'user': f"{settings['uid']}:{settings['gid']}", 'read_only': True,
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
