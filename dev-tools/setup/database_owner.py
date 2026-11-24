"""Provision a separately revocable game/website identity on a managed remote database."""

import argparse
import json
import os
import pwd
from pathlib import Path
import re
import shlex
import sys

from accounts import provision_game_account
from assets import sha256_file
from migration import ssh_arguments
from operations import operation_lock, read_json, run, save_json, write_private
import sshd
import website

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'server-db/tools'))
from mysql_session import MySQL

MAX_REQUEST_BYTES = 16384


def prepare_client(instance, settings):
    database = settings['database']
    owner = database.get('owner_remote')
    if not owner or database.get('owner_provisioned'):
        return
    if settings.get('website') and not settings['website'].get('user'):
        import secrets
        settings['website']['user'] = 'web_' + secrets.token_hex(8)
        settings['website']['password'] = secrets.token_hex(24)
    tunnel_key = instance / 'database-tunnel-key'
    if not tunnel_key.exists():
        run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-C', settings['project'], '-f', str(tunnel_key)])
    save_json(instance / 'installation.json', settings)
    request = {
        'tunnel_key': Path(str(tunnel_key) + '.pub').read_text().strip(),
        'project': settings['project'],
        'game': {'user': database['user'], 'password': database['password']},
    }
    if settings.get('website'):
        request['website'] = {key: settings['website'][key] for key in ('user', 'password')}
    request_path = instance / '.database-owner-request.json'
    save_json(request_path, request)
    arguments = ['python3', '-B', owner['root'] + '/dev-tools/setup/database_owner.py',
                 '--instance-dir', owner['instance']]
    if owner.get('sudo'):
        arguments = ['sudo', '-n', *arguments]
    endpoint = database['ssh']['user'] + '@' + database['ssh']['host']
    try:
        with request_path.open('rb') as incoming:
            response = run([*ssh_arguments(database), endpoint, shlex.join(arguments)], stdin=incoming)
        connection = json.loads(response)
    finally:
        request_path.unlink(missing_ok=True)
    if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]{0,62}4', connection['name']):
        raise ValueError('Database owner returned an invalid schema name')
    if type(connection['port']) is not int or not 1 <= connection['port'] <= 65535:
        raise ValueError('Database owner returned an invalid port')
    if not re.fullmatch(r'ocj_dbssh_[0-9a-f]{8}', connection['ssh_user']):
        raise ValueError('Database owner returned an invalid tunnel identity')
    database['ssh']['user'] = connection['ssh_user']
    database['ssh']['key'] = str(tunnel_key)
    database.update(mode='existing', name=connection['name'], host='127.0.0.1',
                    port=connection['port'], owner_provisioned=True)
    save_json(instance / 'installation.json', settings)


def provision_client(instance, request):
    """Only this selected ready owner may grant a new client access to its own schema."""
    owner = read_json(instance / 'installation.json')
    if owner.get('instance_dir') != str(instance) or owner.get('state') != 'ready':
        raise ValueError('Select the original, ready database-owning installation')
    database = owner['database']
    if database['mode'] != 'new' or not database.get('publish_port'):
        raise ValueError('Database owner must have its loopback SSH-sharing port enabled')
    if sha256_file(instance / 'compose.json') != owner['managed_hashes']['compose.json']:
        raise ValueError('Owner Compose configuration changed; preserved')
    if not re.fullmatch(r'opencj-[a-z0-9-]{1,64}', request['project']):
        raise ValueError('Invalid client project')
    for role, prefix in (('game', 'game_'), ('website', 'web_')):
        if role not in request:
            continue
        account = request[role]
        if not re.fullmatch(prefix + r'[0-9a-f]{16}', account['user']):
            raise ValueError('Invalid client account name')
        if not re.fullmatch(r'[0-9a-f]{48}', account['password']):
            raise ValueError('Invalid generated client credential')
    clients = instance / 'clients'
    clients.mkdir(mode=0o700, exist_ok=True)
    record = clients / (request['project'] + '.json')
    if record.exists() and read_json(record) != request:
        raise ValueError('Client registration changed; existing credentials preserved')
    save_json(record, request)
    container = run(['docker', 'compose', '-p', owner['project'], '-f', str(instance / 'compose.json'),
                     'ps', '--status', 'running', '--quiet', 'db'])
    settings = {'project': request['project'], 'database': {
        'name': database['name'], **request['game']}}
    if request.get('website'):
        settings['website'] = request['website']
    with MySQL(container, database['name']) as db:
        provision_game_account(db, settings)
        if request.get('website'):
            website.provision(db, settings)
    ssh_user = provision_tunnel(request, database['publish_port'])
    return {'name': database['name'], 'port': database['publish_port'], 'ssh_user': ssh_user}


def provision_tunnel(request, port):
    """Install a no-session SSH identity with forwarding limited to this database socket."""
    if os.geteuid() != 0:
        raise RuntimeError('Remote database ownership requires sudo to restrict its SSH tunnel account')
    public_key = request['tunnel_key']
    if not re.fullmatch(r'ssh-ed25519 [A-Za-z0-9+/]{68}={0,2}(?: [A-Za-z0-9-]+)?', public_key):
        raise ValueError('Invalid tunnel public key')
    suffix = request['project'].rsplit('-', 1)[1]
    if not re.fullmatch(r'[0-9a-f]{8}', suffix):
        raise ValueError('Invalid tunnel owner suffix')
    name = 'ocj_dbssh_' + suffix
    marker = 'OpenCJ ' + request['project'] + ' remote database tunnel'
    try:
        account = pwd.getpwnam(name)
    except KeyError:
        run(['useradd', '--system', '--user-group', '--no-create-home', '--home-dir', '/nonexistent',
             '--shell', '/usr/sbin/nologin', '--comment', marker, name])
        account = pwd.getpwnam(name)
    if (account.pw_gecos != marker or account.pw_shell != '/usr/sbin/nologin' or account.pw_uid == 0
            or os.getgrouplist(name, account.pw_gid) != [account.pw_gid]):
        raise RuntimeError('Remote tunnel account permissions differ; preserved')
    status = run(['passwd', '--status', name]).split()
    if len(status) < 2 or status[1] != 'L':
        raise RuntimeError('Remote tunnel account password is not locked')
    key_directory = Path('/etc/ssh/opencj-authorized-keys')
    key_directory.mkdir(mode=0o755, exist_ok=True)
    key_directory.chmod(0o755)
    key_path = key_directory / name
    authorized_key = ('restrict,port-forwarding,permitopen="127.0.0.1:' + str(port) +
                      '",command="/usr/sbin/nologin" ' + public_key + '\n')
    if key_path.exists() and key_path.read_text() != authorized_key:
        raise RuntimeError('Existing remote tunnel key differs; preserved')
    write_private(key_path, authorized_key)
    key_path.chmod(0o644)
    configuration = ('# Managed by OpenCJ setup\nMatch User ' + name + '\n'
                     '    AuthorizedKeysFile ' + str(key_path) + '\n'
                     '    AuthenticationMethods publickey\n    PasswordAuthentication no\n'
                     '    KbdInteractiveAuthentication no\n    AllowTcpForwarding local\n'
                     '    PermitOpen 127.0.0.1:' + str(port) + '\n'
                     '    AllowStreamLocalForwarding no\n    AllowAgentForwarding no\n'
                     '    X11Forwarding no\n    PermitTTY no\n    MaxSessions 0\nMatch all\n')
    config_path = Path('/etc/ssh/sshd_config.d') / ('opencj-' + name + '.conf')
    if config_path.exists() and config_path.read_text() != configuration:
        raise RuntimeError('Existing SSH restriction differs; preserved')
    write_private(config_path, configuration)
    config_path.chmod(0o644)
    sshd.sshd('-t')
    effective = sshd.sshd('-T', '-C', 'user=' + name + ',host=localhost,addr=127.0.0.1')
    required = {'allowtcpforwarding local', 'permitopen 127.0.0.1:' + str(port), 'maxsessions 0',
                'authorizedkeysfile ' + str(key_path), 'authenticationmethods publickey'}
    if not required <= set(effective.splitlines()):
        raise RuntimeError('Host SSH policy overrides the required tunnel restrictions')
    sshd.reload()
    return name


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--instance-dir', type=Path, required=True)
    args = parser.parse_args()
    instance = args.instance_dir.resolve()
    payload = sys.stdin.read(MAX_REQUEST_BYTES + 1)
    if len(payload) > MAX_REQUEST_BYTES:
        raise ValueError('Client provisioning request is too large')
    with operation_lock(instance / '.setup.lock'):
        result = provision_client(instance, json.loads(payload))
    print(json.dumps(result))


if __name__ == '__main__':
    main()
