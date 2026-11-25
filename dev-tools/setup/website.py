"""Configure the shipped website as an isolated, instance-owned Compose project."""

import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets

from accounts import provision_owned_account
from assets import sha256_file
from compose_config import bind, connection_host, database_network, LOGGING
from configuration import ask, ask_port, choose_port, safe_cvar, validate_port
from operations import run, save_json, write_private

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('web_access', ROOT / 'web/tools/grant_web_access.py')
web_access = importlib.util.module_from_spec(spec)
spec.loader.exec_module(web_access)

DEFAULT_DISCORD_INVITE = 'https://discord.gg/VDtbYExYWd'
# Caddy obtains and renews Let's Encrypt certificates by itself.
CADDY_IMAGE = 'caddy:2.8.4-alpine'
# Unprivileged container ports; the host's 80/443 are mapped onto them, so Caddy
# needs no capability to bind low ports.
CADDY_HTTP_PORT = 8080
CADDY_HTTPS_PORT = 8443
DOMAIN_PATTERN = r'(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}'


def validate_domain(domain):
    if domain and not re.fullmatch(DOMAIN_PATTERN, domain):
        raise ValueError('use a domain name such as opencj.org (lowercase, no http://)')
    return domain


def validate_email(address):
    if address and not re.fullmatch(r'[^@\s]+@[^@\s]+\.[a-z]{2,63}', address):
        raise ValueError('use an e-mail address or leave it blank')
    return address


def validate_invite(invite):
    if invite == 'disabled':
        return ''
    if invite and not re.fullmatch(r'https://(discord\.gg|discord\.com/invite)/[A-Za-z0-9-]+', invite):
        raise ValueError('use a https://discord.gg/... invite, or "disabled"')
    return invite


def parse_aliases(text):
    """Comma-separated extra domains; 'none' clears them."""
    if text.strip() in ('', 'none'):
        return []
    aliases = [validate_domain(alias.strip()) for alias in text.split(',') if alias.strip()]
    if len(aliases) != len(set(aliases)):
        raise ValueError('list each domain once')
    return aliases


def collect_website(game_port, *, current=None, game_address=''):
    """Ask for the public website; with a domain it is served over HTTPS on ports 80/443.

    current holds the existing website settings when they are being changed; they
    become the defaults. Extra domains redirect to the main domain, so every visitor
    ends up on one address.
    """
    current = current or {}
    print('With a domain name, the website is served over HTTPS (free Let\'s Encrypt certificate,'
          ' renewed automatically). Setup lists the DNS records to create and checks them.', flush=True)
    domain = ask('Main website domain, for example opencj.org (blank: only reachable from this machine)',
                 current.get('domain', ''), parse=validate_domain)
    result = {'domain': domain, 'aliases': [], 'bind_ip': current.get('bind_ip', '127.0.0.1')}
    if domain:
        aliases = parse_aliases(ask('Other domains that open the same website, comma-separated, for example'
                                    ' opencj.net (they redirect to ' + domain + '; "none" for none)',
                                    ', '.join(current.get('aliases', [])) or 'none'))
        if domain in aliases:
            raise ValueError('The main domain cannot also be an extra domain')
        result['aliases'] = aliases
    result['port'] = current.get('port') or ask_port('Local website port (for checks and tunnels)', choose_port(8090))
    default_address = (game_address or domain or 'localhost') + ':' + str(game_port)
    result['connect_address'] = ask('Game address shown on the website', current.get('connect_address')
                                    or default_address)
    result['discord_invite'] = ask('Discord invite URL, or disabled',
                                   current.get('discord_invite', DEFAULT_DISCORD_INVITE) or 'disabled',
                                   parse=validate_invite)
    if domain:
        result['acme_email'] = ask('E-mail for certificate problems (optional)', current.get('acme_email', ''),
                                   parse=validate_email)
    return result


def validate_website(website, database):
    result = dict(website)
    result.setdefault('bind_ip', '127.0.0.1')
    ipaddress.IPv4Address(result['bind_ip'])
    result.setdefault('port', 8090)
    validate_port(result['port'])
    safe_cvar(result['connect_address'])
    result.setdefault('discord_invite', DEFAULT_DISCORD_INVITE)
    result['discord_invite'] = validate_invite(result['discord_invite'])
    result['domain'] = validate_domain(result.get('domain', ''))
    aliases = result.get('aliases', [])
    if not isinstance(aliases, list):
        raise ValueError('website.aliases must be a list of domains')
    result['aliases'] = parse_aliases(','.join(aliases))
    if result['aliases'] and not result['domain']:
        raise ValueError('Extra website domains need a main domain')
    if result['domain'] in result['aliases']:
        raise ValueError('The main domain cannot also be an extra domain')
    result['acme_email'] = validate_email(result.get('acme_email', ''))
    if database['mode'] == 'existing' and not database.get('owner_instance'):
        if not result.get('user') or not result.get('password'):
            raise ValueError('The external database owner must supply a dedicated website account')
    return result


def caddyfile(website):
    """HTTPS for the whole site; plain HTTP stays available only for in-game map downloads.

    Extra domains get their own certificates and redirect to the main domain.
    """
    options = ['\thttp_port ' + str(CADDY_HTTP_PORT), '\thttps_port ' + str(CADDY_HTTPS_PORT), '\tadmin off',
               # HTTP/3 needs UDP 443, which is not published; offer HTTP/1.1 and HTTP/2.
               '\tservers {', '\t\tprotocols h1 h2', '\t}']
    if website['acme_email']:
        options.append('\temail ' + website['acme_email'])
    domain = website['domain']
    aliases = website.get('aliases', [])
    text = ('{\n' + '\n'.join(options) + '\n}\n\n'
            + domain + ' {\n\tencode gzip\n\treverse_proxy httpd:8080\n}\n\n')
    if aliases:
        text += ', '.join(aliases) + ' {\n\tredir https://' + domain + '{uri} permanent\n}\n\n'
    # CoD4 clients download maps over plain HTTP only (sv_wwwBaseURL http://...).
    plain_sites = ', '.join('http://' + name for name in [domain, *aliases])
    return (text + plain_sites + ' {\n\thandle /usermaps/* {\n\t\treverse_proxy httpd:8080\n\t}\n'
            + '\thandle {\n\t\tredir https://' + domain + '{uri} permanent\n\t}\n}\n')


def add_https_proxy(document, settings, directory):
    identity = settings['linux_accounts']['http']
    data = directory / 'caddy-data'
    data.mkdir(mode=0o700, exist_ok=True)
    os.chown(data, identity['uid'], identity['gid'])
    config = directory / 'Caddyfile'
    write_private(config, caddyfile(settings['website']))
    config.chmod(0o644)
    document['services']['https'] = {
        'image': CADDY_IMAGE, 'restart': 'unless-stopped', 'logging': LOGGING, 'pids_limit': 128,
        'user': f"{identity['uid']}:{identity['gid']}", 'read_only': True, 'cap_drop': ['ALL'],
        # The image marks /usr/bin/caddy with the bind-low-ports file capability; with
        # no-new-privileges the kernel refuses to start it unless that capability is in
        # the container's set. Caddy still only listens on 8080/8443 here.
        'cap_add': ['NET_BIND_SERVICE'],
        'security_opt': ['no-new-privileges:true'],
        'environment': {'XDG_DATA_HOME': '/data', 'XDG_CONFIG_HOME': '/tmp/config'},
        'tmpfs': ['/tmp'],
        'command': ['caddy', 'run', '--config', '/etc/caddy/Caddyfile', '--adapter', 'caddyfile'],
        'ports': ['80:' + str(CADDY_HTTP_PORT), '443:' + str(CADDY_HTTPS_PORT)],
        'volumes': [bind(config, '/etc/caddy/Caddyfile'), bind(data, '/data', readonly=False)],
        'networks': {'public': {}},
        'depends_on': {'httpd': {'condition': 'service_started'}},
    }


def command(instance, settings, *arguments):
    return ['docker', 'compose', '-p', settings['project'] + '-web',
            '-f', str(instance / 'website/compose.json'), *arguments]


def prepare(instance, settings, *, replace=False):
    """Keep per-installation settings out of the source website's .env file.

    replace=True regenerates the project after a deliberate settings change or upgrade.
    """
    website = settings.get('website')
    if not website:
        return
    directory = instance / 'website'
    directory.mkdir(mode=0o700, exist_ok=True)
    if 'user' not in website:
        website['user'] = 'web_' + secrets.token_hex(8)
        website['password'] = secrets.token_hex(24)
    identity = settings['linux_accounts']['website']
    owner = (identity['uid'], identity['gid'])
    write_private(directory / 'database-password', website['password'], owner=owner)
    usermaps = Path(settings['game_dir']) / 'usermaps'
    if not usermaps.is_dir():
        usermaps = directory / 'empty-maps'
        usermaps.mkdir(mode=0o755, exist_ok=True)
    # Resolve the maintained Compose template with placeholders, then supply the
    # secret through a file. No real password enters Docker's environment metadata.
    environment = {
        'WEB_DB_PASSWORD': 'provided-through-secret-file',
        'WEB_USERMAPS_DIR': str(usermaps),
        'WEB_USERMAPS_GID': str(usermaps.stat().st_gid),
        'WEB_GAME_NETWORK': database_network(settings),
        'WEB_BIND_IP': website['bind_ip'],
        'WEB_PORT': str(website['port']),
    }
    env_path = directory / 'compose.env'
    write_private(env_path, ''.join(key + '=' + value + '\n' for key, value in environment.items()))
    source = ['docker', 'compose', '--env-file', str(env_path),
              '--project-directory', str(ROOT / 'web'), '-p', settings['project'] + '-web',
              '-f', str(ROOT / 'web/compose.yaml')]
    document = json.loads(run([*source, 'config', '--format', 'json']))
    generator = document['services']['generator']
    generator['image'] = settings['project'] + '-web:' + settings['release']
    generator['build']['args'] = {'WEB_USER_ID': str(identity['uid'])}
    generator['user'] = f"{identity['uid']}:{identity['gid']}"
    generator['environment'].pop('WEB_DB_PASSWORD', None)
    generator['environment'].update({
        'WEB_DB_PASSWORD_FILE': '/run/secrets/database-password',
        'WEB_DB_HOST': connection_host(settings),
        'WEB_DB_PORT': str(3306 if settings['database'].get('transport') == 'ssh' else settings['database']['port']),
        'WEB_DB_NAME': settings['database']['name'],
        'WEB_DB_USER': website['user'],
        'WEB_GAME_HOST': settings['project'] + '-game',
        'WEB_CONNECT_ADDRESS': website['connect_address'],
        'WEB_DISCORD_INVITE_URL': website['discord_invite'],
    })
    generator['volumes'].append(bind(directory / 'database-password', '/run/secrets/database-password'))
    generator['group_add'] = [group for group in generator.get('group_add', []) if str(group) != '0']
    generator['healthcheck'] = {
        'test': ['CMD', 'python', '-c',
                 'import pathlib\nimport time\n'
                 'page = pathlib.Path("/srv/output/current/index.html")\n'
                 'assert page.is_file() and time.time() - page.stat().st_mtime < 180'],
        'interval': '10s', 'timeout': '5s', 'retries': 18, 'start_period': '180s',
    }
    for service in document['services'].values():
        service['logging'] = LOGGING
        service['pids_limit'] = 128
    for mount in document['services']['httpd']['volumes']:
        if mount['type'] == 'volume':
            mount['volume'] = {'nocopy': True}
    http_identity = settings['linux_accounts']['http']
    document['services']['httpd']['user'] = f"{http_identity['uid']}:{http_identity['gid']}"
    document['services']['httpd']['healthcheck'] = {
        'test': ['CMD', 'wget', '-q', '-O', '/dev/null', 'http://127.0.0.1:8080/'],
        'interval': '10s', 'timeout': '5s', 'retries': 18, 'start_period': '180s',
    }
    if website['domain']:
        add_https_proxy(document, settings, directory)
    path = directory / 'compose.json'
    if path.exists() and not replace and path.read_text() != json.dumps(document, indent=2) + '\n':
        raise RuntimeError('Website configuration changed; existing project preserved')
    save_json(path, document)
    website['compose_hash'] = sha256_file(path)


def provision(db, settings):
    """Use the website's maintained table allowlist; deny unrelated reads and all writes."""
    website = settings['website']
    tables = set(db.query(
        'SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE();').splitlines())
    if not set(web_access.WEB_READABLE_TABLES) <= tables:
        raise RuntimeError('Website tables are missing; apply the complete migration set first')
    principal = provision_owned_account(
        db, website['user'], website['password'], settings['project'],
        connection_limit=web_access.MAX_ACCOUNT_CONNECTIONS)
    for statement in web_access.grant_statements(settings['database']['name'], principal,
                                                 web_access.WEB_READABLE_TABLES):
        db.query(statement)


def check_grants(db, settings):
    """Verify the read-only boundary through the website identity itself."""
    quote = web_access.quote_identifier
    database = settings['database']['name']
    expected = {'*.*': {'USAGE'}}
    for table in web_access.WEB_READABLE_TABLES:
        expected[quote(database) + '.' + quote(table)] = {'SELECT'}
    actual = {}
    for grant in db.query('SHOW GRANTS FOR CURRENT_USER;').splitlines():
        privileges, separator, remainder = grant.removeprefix('GRANT ').partition(' ON ')
        scope, target_separator, principal = remainder.partition(' TO ')
        values = {value.strip() for value in privileges.split(',')}
        if (not grant.startswith('GRANT ') or not separator or not target_separator
                or 'WITH GRANT OPTION' in principal or scope not in expected or values != expected[scope]):
            raise RuntimeError('Website account has privileges outside its table allowlist')
        actual[scope] = values
    if actual != expected:
        raise RuntimeError('Website account is missing required table permissions')


def start(instance, settings):
    run(command(instance, settings, 'up', '-d', '--build', '--wait', '--wait-timeout', '300'),
        timeout=1800, log=instance / 'website.log')


def check(instance, settings):
    website = settings['website']
    if sha256_file(instance / 'website/compose.json') != website['compose_hash']:
        raise RuntimeError('Website configuration changed; preserved')
    containers = run(command(instance, settings, 'ps', '--quiet')).splitlines()
    expected_services = 3 if website['domain'] else 2
    if len(containers) != expected_services:
        raise RuntimeError('Expected all website services to run')
    metadata = json.loads(run(['docker', 'inspect', *containers]))
    for item in metadata:
        health = item['State'].get('Health', {}).get('Status')
        # The HTTPS proxy has no healthcheck: certificates can take a while after DNS
        # changes, and Caddy keeps retrying by itself.
        if health is None and item['State']['Running']:
            continue
        if health != 'healthy':
            raise RuntimeError('Website has not published a healthy page')
