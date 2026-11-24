#!/usr/bin/env python3
"""Exercise real disposable installations with explicitly supplied licensed CoD4 assets."""

import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'dev-tools/setup'))
import install
from configuration import choose_port
import linux_accounts
import website as managed_website


def command(arguments, *, timeout=2400):
    result = subprocess.run(arguments, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f'Fixture command failed: {arguments[0]} {arguments[1]}')
    return result.stdout.strip()


def read_settings(instance):
    return json.loads((instance / 'installation.json').read_text())


def inspect_server(instance):
    settings = read_settings(instance)
    container = install.compose(instance, settings, 'ps', '--quiet', 'server')
    return json.loads(command(['docker', 'inspect', container]))[0]


def assert_game_reply(port):
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
        client.settimeout(5)
        client.sendto(b'\xff\xff\xff\xffgetstatus\n', ('127.0.0.1', port))
        response = client.recv(16384)
    assert response.startswith(b'\xff\xff\xff\xffstatusResponse')
    assert b'\\sv_maxclients\\32' in response
    assert b'\\opencj_version\\beta-0.1.0' in response
    assert b'\\pswrd\\1' in response


def create_instance(evidence, label, assets, database, instances, *, website=None, copy_from=None):
    """Record ownership before invoking setup so a failing first run is still cleaned."""
    instance = evidence / label
    instances.append(instance)
    answers = {'name': 'fixture-' + label, 'hostname': 'OpenCJ setup fixture',
               'pruning': {'enabled': False}, 'geoip': {'enabled': False},
               'game_assets': assets.game_dir, 'mod_assets': assets.mod_dir,
               'port': choose_port(31000), 'bind_ip': '127.0.0.1', 'database': database}
    if website:
        answers['website'] = website
    if copy_from:
        answers['migration'] = {'transport': 'local', 'source_root': str(ROOT),
                                'source_instance': str(copy_from), 'intent': 'rehearsal'}
    answer_file = evidence / (label + '-answers.json')
    answer_file.write_text(json.dumps(answers))
    answer_file.chmod(0o600)
    arguments = [sys.executable, '-B', str(ROOT / 'dev-tools/setup/install.py'),
                 '--instance-dir', str(instance), '--config', str(answer_file)]
    print('SETUP FIXTURE installing ' + label, flush=True)
    result = subprocess.run(arguments, capture_output=True, text=True, timeout=2400)
    (evidence / (label + '-install.log')).write_text(result.stdout + result.stderr)
    answer_file.unlink()
    if result.returncode:
        raise RuntimeError('Installation failed: ' + label + '; inspect its private failure/log files')
    settings = read_settings(instance)
    assert settings['state'] == 'ready'
    linux_accounts.verify_accounts(settings)
    assert_game_reply(settings['port'])
    server = inspect_server(instance)
    assert server['Config']['User'] == f"{settings['uid']}:{settings['gid']}"
    assert settings['uid'] != 0 and server['HostConfig']['ReadonlyRootfs']
    assert server['HostConfig']['CapDrop'] == ['ALL']
    logs = command(['docker', 'logs', server['Id']])
    (evidence / (label + '-server.log')).write_text(logs)
    for marker in ('SCRIPT ERROR', 'script runtime error', 'unknown function',
                   'OpenCJ SQL: persistence request failed'):
        assert marker.lower() not in logs.lower(), 'Server startup reported ' + marker
    return instance, settings


def verify_preservation(instance, settings):
    before = inspect_server(instance)
    original_record = (instance / 'installation.json').read_bytes()
    with install.database_client(instance, settings, administrator=True) as db:
        db.query('CREATE TABLE setupSentinel(value INT NOT NULL); INSERT INTO setupSentinel VALUES(42);')
    arguments = [sys.executable, '-B', str(ROOT / 'dev-tools/setup/install.py'), '--instance-dir', str(instance)]
    command(arguments)
    after = inspect_server(instance)
    assert (before['Id'], before['State']['StartedAt']) == (after['Id'], after['State']['StartedAt'])
    assert (instance / 'installation.json').read_bytes() == original_record
    with install.database_client(instance, settings) as db:
        assert db.query('SELECT value FROM setupSentinel;') == '42'
    container = install.compose(instance, settings, 'ps', '--quiet', 'db')
    with install.MySQL(container, settings['database']['name'], runtime=True) as db:
        assert db.query('SELECT value FROM setupSentinel;') == '42'
    with install.database_client(instance, settings, administrator=True) as db:
        try:
            install.bootstrap.bootstrap(db, settings['database']['name'])
        except RuntimeError as error:
            assert 'empty database' in str(error)
        else:
            raise AssertionError('Repeated bootstrap overwrote existing data')
    with install.database_client(instance, settings) as db:
        try:
            db.query('DROP TABLE setupSentinel;')
        except RuntimeError as error:
            assert 'denied' in str(error).lower()
        else:
            raise AssertionError('Gameplay account could drop historical data')
    # Deliberately overprivilege only this owned synthetic account, then restore it.
    with install.database_client(instance, settings, administrator=True) as db:
        db.query("GRANT FILE ON *.* TO '" + settings['database']['user'] + "'@'%';")
    try:
        with install.database_client(instance, settings) as db:
            try:
                install.check_runtime_grants(db)
            except RuntimeError as error:
                assert 'outside the reviewed' in str(error)
            else:
                raise AssertionError('Setup accepted a global filesystem privilege')
    finally:
        with install.database_client(instance, settings, administrator=True) as db:
            db.query("REVOKE FILE ON *.* FROM '" + settings['database']['user'] + "'@'%';")
    with install.database_client(instance, settings) as db:
        install.check_runtime_grants(db)
    config = instance / 'server.cfg'
    original_config = config.read_bytes()
    config.write_bytes(original_config + b'// operator edit preserved\n')
    failed = subprocess.run(arguments, capture_output=True, timeout=180)
    assert failed.returncode != 0
    assert config.read_bytes() == original_config + b'// operator edit preserved\n'
    assert inspect_server(instance)['State']['StartedAt'] == before['State']['StartedAt']
    config.write_bytes(original_config)


def create_ssh_fixture(evidence, settings, resources):
    """Use disposable keys and an isolated sshd to exercise actual encrypted database forwarding."""
    directory = evidence / 'ssh-fixture'
    directory.mkdir()
    for name in ('host', 'client'):
        command(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(directory / name)])
    (directory / 'known_hosts').write_text('[setup-ssh]:2222 ' + (directory / 'host.pub').read_text())
    dockerfile = directory / 'Dockerfile'
    dockerfile.write_text('FROM opencj-builder:beta-0.1.0\n'
                         'RUN apt-get update && apt-get install -y openssh-server '
                         '&& mkdir -p /run/sshd && passwd -d root\n')
    image = settings['project'] + '-sshd'
    resources['images'].append(image)
    command(['docker', 'build', '-t', image, str(directory)])
    container = settings['project'] + '-sshd'
    resources['containers'].append(container)
    command(['docker', 'run', '-d', '--name', container, '--network', settings['project'] + '_default',
             '--network-alias', 'setup-ssh', '-v', f'{directory / "host"}:/run/host_key:ro',
             '-v', f'{directory / "client.pub"}:/run/authorized_keys:ro', image,
             '/usr/sbin/sshd', '-D', '-e', '-p', '2222', '-o', 'PasswordAuthentication=no',
             '-o', 'KbdInteractiveAuthentication=no', '-o', 'UsePAM=no', '-o', 'StrictModes=no',
             '-o', 'PermitRootLogin=prohibit-password', '-o', 'HostKey=/run/host_key',
             '-o', 'AuthorizedKeysFile=/run/authorized_keys'])
    return {'mode': 'existing', 'transport': 'ssh', 'network': settings['project'] + '_default',
            'host': 'db', 'port': 3306, 'name': settings['database']['name'], 'user': settings['database']['user'],
            'password': settings['database']['password'],
            'ssh': {'host': 'setup-ssh', 'port': 2222, 'user': 'root',
                    'key': str(directory / 'client'), 'known_hosts': str(directory / 'known_hosts')}}


def cleanup(instances, resources):
    """Remove only recorded fixture resources; report cleanup failures instead of hiding them."""
    failures = []
    for container in resources['containers']:
        try:
            command(['docker', 'rm', '-f', container])
        except RuntimeError:
            failures.append('Could not remove fixture SSH container')
    for instance in reversed(instances):
        if not (instance / 'installation.json').exists():
            continue
        settings = read_settings(instance)
        try:
            if settings.get('website'):
                command(managed_website.command(instance, settings, 'down', '--volumes'), timeout=90)
            if settings.get('website_compose'):
                command(install.website_command(settings, 'down', '--volumes'), timeout=90)
            if (instance / 'compose.json').exists():
                install.compose(instance, settings, 'down', '--volumes', timeout=90)
            if settings['database']['mode'] == 'new':
                volumes = command(['docker', 'volume', 'ls', '--format', '{{.Name}}'])
                if settings['volume'] in volumes.splitlines():
                    metadata = json.loads(command(['docker', 'volume', 'inspect', settings['volume']]))[0]
                    assert metadata['Labels']['org.opencj.instance'] == settings['project']
                    command(['docker', 'volume', 'rm', settings['volume']])
            images = command(['docker', 'image', 'ls', '--format', '{{.Repository}}:{{.Tag}}'])
            if settings['image'] in images.splitlines():
                command(['docker', 'image', 'rm', settings['image']])
            if settings.get('website'):
                command(['docker', 'image', 'rm', settings['project'] + '-web:' + settings['release']])
                (instance / 'website/database-password').unlink(missing_ok=True)
            install.linux_accounts.remove_fixture_accounts(settings)
            for path in (instance / 'secrets').glob('*'):
                path.unlink()
            for name in ('installation.json', 'server.cfg', 'join-password', 'rcon-password'):
                (instance / name).unlink(missing_ok=True)
        except Exception as error:
            failures.append(type(error).__name__ + ': fixture ' + instance.name)
    for image in resources['images']:
        try:
            command(['docker', 'image', 'rm', image])
        except RuntimeError:
            failures.append('Could not remove fixture SSH image')
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game-dir', required=True)
    parser.add_argument('--mod-dir', required=True)
    assets = parser.parse_args()
    if os.geteuid() != 0:
        parser.error('Run with sudo: installation tests create dedicated Linux service users')
    os.umask(0o077)
    evidence = ROOT / 'dev-tools/local' / ('setup-integration-' + uuid.uuid4().hex[:8])
    evidence.mkdir(parents=True)
    instances = []
    resources = {'containers': [], 'images': []}
    report = {'passed': False, 'checks': []}
    try:
        main_instance, settings = create_instance(evidence, 'main', assets,
            {'mode': 'new', 'name': 'setup_main_cod4', 'publish_port': 0}, instances)
        report['checks'].append('fresh custom schema, 32 slots and game-protocol health')
        verify_preservation(main_instance, settings)
        report['checks'].append('repeat setup preserves process, credentials, configuration and synthetic records')
        report['checks'].append('repeated bootstrap and runtime DDL refused')
        other_instance, other = create_instance(evidence, 'acceptance', assets,
            {'mode': 'new', 'name': 'setup_acceptance_cod4', 'publish_port': 0}, instances)
        assert settings['volume'] != other['volume']
        with install.database_client(other_instance, other) as db:
            assert db.query("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name='setupSentinel';") == '0'
        report['checks'].append('second local instance has independent ports, network and data')
        copied_instance, copied = create_instance(evidence, 'copied', assets,
            {'mode': 'new', 'publish_port': 0}, instances, copy_from=main_instance)
        with install.database_client(copied_instance, copied, administrator=True) as db:
            assert db.query('SELECT value FROM setupSentinel;') == '42'
            db.query('UPDATE setupSentinel SET value=99;')
        with install.database_client(main_instance, settings) as db:
            assert db.query('SELECT value FROM setupSentinel;') == '42'
        report['checks'].append('consistent copied database has independent subsequent writes')
        website = {'bind_ip': '127.0.0.1', 'port': choose_port(8090),
                   'connect_address': 'localhost:' + str(settings['port']), 'discord_invite': ''}
        shared_instance, shared = create_instance(evidence, 'shared', assets,
            {'mode': 'instance', 'instance_dir': str(main_instance)}, instances, website=website)
        with install.database_client(shared_instance, shared) as db:
            assert db.query('SELECT value FROM setupSentinel;') == '42'
        assert shared['database']['user'] != settings['database']['user']
        assert shared['uid'] != settings['uid']
        managed_website.check(shared_instance, shared)
        with install.database_client(shared_instance, shared, website=True) as db:
            managed_website.check_grants(db, shared)
            try:
                db.query('SELECT * FROM playerInformation LIMIT 1;')
            except RuntimeError as error:
                assert 'denied' in str(error).lower()
            else:
                raise AssertionError('Website could read private player information')
        report['checks'].append('shared data with unique users, real website and private-table denial')
        remote_database = create_ssh_fixture(evidence, settings, resources)
        remote_instance, remote = create_instance(evidence, 'ssh', assets, remote_database, instances)
        with install.database_client(remote_instance, remote) as db:
            assert db.query('SELECT value FROM setupSentinel;') == '42'
        report['checks'].append('actual pinned-host-key SSH database forwarding and gameplay startup')
        report['passed'] = True
    except Exception as error:
        report['failure'] = str(error)
        raise
    finally:
        report['cleanup_failures'] = cleanup(instances, resources)
        for key in ('client', 'host'):
            (evidence / 'ssh-fixture' / key).unlink(missing_ok=True)
        if report['cleanup_failures']:
            report['passed'] = False
        (evidence / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
        print('SETUP FIXTURE result: ' + str(evidence / 'result.json'), flush=True)
        if report['cleanup_failures']:
            raise RuntimeError('Fixture cleanup incomplete; see private result')
    print(json.dumps(report), flush=True)


if __name__ == '__main__':
    main()
