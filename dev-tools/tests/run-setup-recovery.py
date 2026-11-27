#!/usr/bin/env python3
"""Exercise setup recovery on a disposable Linux host with a separately built release image.

Only operator input and the expensive image build are substituted. Docker, MySQL,
service identities, console status, restores, migrations and the bounded receiver
filesystem are real. Never run on a production host.
"""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import uuid
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'dev-tools/setup'))
import configuration
import install
import maintenance
import manage
import offsite
from operations import read_json, run, save_json
import service_control
import source

spec = importlib.util.spec_from_file_location('setup_fixture', ROOT / 'dev-tools/tests/run-server-setup.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


def create(host, name, args, instances, *, owner=None):
    instance = host / name
    instance.mkdir()
    instances.append(instance)
    database = {'mode': 'instance', 'instance_dir': str(owner)} if owner else {
        'mode': 'new', 'name': 'fixture_cod4', 'publish_port': 0}
    settings = install.initialize_instance(instance, {
        'name': name, 'hostname': 'Recovery fixture', 'database': database,
        'game_assets': args.game_dir, 'mod_assets': args.mod_dir, 'on_demand': False,
        'port': configuration.choose_port(32000), 'bind_ip': '127.0.0.1',
        'backups': {'enabled': False}, 'pruning': {'enabled': False}, 'geoip': {'enabled': False}})
    use_image(instance, settings, args.image)
    install.save_installation(instance, settings)
    install.install(instance, settings)
    return instance, install.load_installation(instance)


def use_image(instance, settings, image):
    run(['docker', 'tag', image, settings['image']])
    settings['image_id'] = run(['docker', 'image', 'inspect', image, '--format', '{{.Id}}'])
    settings['source_revision'] = run(['docker', 'image', 'inspect', image,
                                     '--format', '{{index .Config.Labels "org.opencontainers.image.revision"}}'])
    settings['engine_revision'] = 'prebuilt-fixture'


def container(instance, settings):
    return install.compose(instance, settings, 'ps', '--quiet', 'server')


def configure_checks(host, instance, settings):
    initial_container = container(instance, settings)
    source.set_source_map(initial_container, 'mp_crash')
    service_control.restore_map(instance, settings, 'mp_crash')
    changed = {**settings, 'hostname': 'Applied recovery settings', 'slots': 16, 'join_password': 'fixture-private-pass'}
    with patch.object(manage, 'collect_changes', return_value=changed), patch.object(manage, 'ask_yes_no', return_value=False):
        manage.configure_instance(host, instance.name)
    assert container(instance, settings) == initial_container, 'Deferred configuration restarted the game'
    with patch.object(manage, 'ask_yes_no', return_value=True):
        manage.start_instance(host, instance.name)
    settings = install.load_installation(instance)
    assert container(instance, settings) != initial_container, 'Accepted configuration did not recreate the game'
    service_control.verify_running_files(instance, settings)
    assert service_control.active_game(instance, settings)['map'] == 'mp_crash'
    status = source.console_output(container(instance, settings), 'sv_maxclients')
    assert '16' in status, 'Running slot count differs from the requested value'
    assert settings['join_password'] in source.console_output(container(instance, settings), 'g_password')
    return settings


def restore_checks(host, instance, settings, peer, shared):
    with install.database_client(instance, settings, administrator=True) as db:
        db.query('CREATE TABLE recoverySentinel(value INT NOT NULL);\n'
                 'INSERT INTO recoverySentinel VALUES(42);')
    backup = host / 'snapshot.sql.gz'
    maintenance.dump_database(instance, settings, backup, byte_limit=maintenance.GIB, reserve_bytes=maintenance.GIB)
    with install.database_client(instance, settings, administrator=True) as db:
        db.query('UPDATE recoverySentinel SET value=99;')
    invalid = host / 'truncated.sql.gz'
    invalid.write_bytes(backup.read_bytes()[:-8])
    before = (container(instance, settings), container(peer, shared))
    try:
        manage.restore_backup(host, instance.name, invalid, assume_yes=True)
    except RuntimeError as error:
        assert 'damaged' in str(error)
    else:
        raise AssertionError('Damaged backup was accepted')
    assert before == (container(instance, settings), container(peer, shared))
    manage.restore_backup(host, instance.name, backup, assume_yes=True)
    assert all(old != new for old, new in zip(before, (container(instance, settings), container(peer, shared))))
    with install.database_client(peer, shared) as db:
        assert db.query('SELECT value FROM recoverySentinel;') == '42'
    assert service_control.active_game(instance, settings)['map'] == 'mp_crash'


def refresh_checks(host, owner, settings, peer, shared, args, instances):
    origin, original = create(host, 'origin', args, instances)
    with install.database_client(origin, original, administrator=True) as db:
        db.query('CREATE TABLE recoverySentinel(value INT NOT NULL);\n'
                 'INSERT INTO recoverySentinel VALUES(7);')
    draft = origin / 'runtime/refresh-draft.txt'
    draft.write_text('source draft')
    os.chown(draft, original['uid'], original['gid'])
    settings['copy_source'] = 'origin'
    install.save_installation(owner, settings)
    manage.refresh_instance(host, owner.name, assume_yes=True)
    with install.database_client(peer, shared) as db:
        assert db.query('SELECT value FROM recoverySentinel;') == '7'
    assert (owner / 'runtime/refresh-draft.txt').read_text() == 'source draft'
    assert service_control.active_game(owner, settings)['map'] == 'mp_crash'
    assert service_control.active_game(origin, original)['map'] == original['map']
    assert len(list(owner.glob('runtime.previous-*'))) == 1


def upgrade_checks(host, instances, image):
    migrations = host / 'upgrade-source/migrations'
    shutil.copytree(ROOT / 'server-db/migrations', migrations)
    version = max(manage.migrate.load_migrations()) + 1
    (migrations / f'{version:03d}-recovery-fixture.sql').write_text('CREATE TABLE recoveryUpgrade(value INT);\n')
    for instance in instances[:2]:
        settings = install.load_installation(instance)
        settings['release'] = 'fixture-previous'
        install.save_installation(instance, settings)
    with patch.object(manage.migrate, 'ROOT', migrations.parent), \
            patch.object(install, 'build_release', side_effect=lambda directory, settings: use_image(directory, settings, image)):
        original_write = install.write_generated
        interrupted = False

        def interrupt_after_replacement(path, text, **options):
            nonlocal interrupted
            original_write(path, text, **options)
            if path == instances[0] / 'server.cfg' and not interrupted:
                interrupted = True
                raise OSError('fixture power failure after config replacement')

        with patch.object(install, 'write_generated', side_effect=interrupt_after_replacement):
            try:
                manage.upgrade_host(host)
            except OSError as error:
                assert 'fixture power failure' in str(error)
            else:
                raise AssertionError('Upgrade interruption was not exercised')
        for instance in instances[:2]:
            settings = install.load_installation(instance, allow_other_release=True)
            assert (instance / service_control.MAINTENANCE_RECORD).exists()
            assert not install.compose(instance, settings, 'ps', '--status', 'running', '--quiet', 'server')
        manage.upgrade_host(host)
        for instance in instances[:2]:
            settings = install.load_installation(instance)
            assert manage.applied_migrations(instance, settings) == version
            assert not (instance / service_control.MAINTENANCE_RECORD).exists()
        with install.database_client(instances[1], install.load_installation(instances[1])) as db:
            assert db.query('SELECT COUNT(*) FROM recoveryUpgrade;') == '0'


def receiver_checks(host):
    receiver = Path('/srv') / ('opencj-receiver-fixture-' + uuid.uuid4().hex[:8])
    name = 'fixture-' + uuid.uuid4().hex[:8]
    account = None
    unit = None
    try:
        offsite.prepare_receiver_storage(receiver, 1)
        unit = run(['systemd-escape', '--path', '--suffix=mount', str(receiver)])
        offsite.prepare_receiver_storage(receiver, 1)
        target = receiver / name
        target.mkdir(mode=0o700)
        account = offsite.ensure_receiver_account(name, target)
        os.chown(target, account.pw_uid, account.pw_gid)
        free_before = shutil.disk_usage(host).free
        fill = subprocess.run(['runuser', '-u', account.pw_name, '--', 'dd', 'if=/dev/zero',
                               'of=' + str(target / '.unfinished'), 'bs=1M', 'count=1100'],
                              capture_output=True, timeout=300)
        assert fill.returncode != 0 and b'No space left' in fill.stderr, 'Receiver limit check failed: ' + fill.stderr.decode(errors='replace')
        assert (target / '.unfinished').stat().st_size < maintenance.GIB
        assert free_before - shutil.disk_usage(host).free < 32 * 1024 ** 2, 'Upload consumed unreserved host disk'
        (target / '.unfinished').unlink()
        run(['systemctl', 'stop', unit])
        try:
            offsite.require_receiver_storage(receiver)
        except RuntimeError as error:
            assert 'not mounted' in str(error)
        else:
            raise AssertionError('Unmounted receiver accepted')
    finally:
        if account:
            run(['userdel', account.pw_name])
        if unit:
            run(['systemctl', 'disable', '--now', unit])
            (Path('/etc/systemd/system') / unit).unlink()
            run(['systemctl', 'daemon-reload'])
        image, record = offsite.receiver_storage_paths(receiver)
        if not os.path.ismount(receiver):
            image.unlink(missing_ok=True)
            record.unlink(missing_ok=True)
            receiver.rmdir()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--disposable-host', action='store_true', required=True)
    parser.add_argument('--game-dir', required=True)
    parser.add_argument('--mod-dir', required=True)
    parser.add_argument('--image', required=True, help='Release image built from the reviewed checkout')
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error('Run as root only on a disposable host')
    os.umask(0o077)
    host = ROOT / 'dev-tools/local' / ('setup-recovery-' + uuid.uuid4().hex[:8])
    host.mkdir(parents=True)
    instances = []
    resources = {'containers': [], 'images': []}
    checks = []
    try:
        owner, settings = create(host, 'main', args, instances)
        peer, shared = create(host, 'shared', args, instances, owner=owner)
        save_json(host / 'host-setup.json', {'host_dir': str(host), 'completed': ['main', 'shared'],
                                          'instances': [settings, shared], 'firewall': {'enabled': False}})
        settings = configure_checks(host, owner, settings)
        checks.append('defer/apply, real recreation, effective password/slots and previous-map restoration')
        restore_checks(host, owner, settings, peer, shared)
        checks.append('damaged archive preservation and real restore with both shared games recreated')
        refresh_checks(host, owner, settings, peer, shared, args, instances)
        checks.append('real source snapshot, shared-target refresh and runtime preservation')
        upgrade_checks(host, instances, args.image)
        checks.append('interrupted upgrade retry, older migration prefix and shared-account grants')
        receiver_checks(host)
        checks.append('repeat bounded-storage setup, real ENOSPC and unmounted-storage refusal')
    finally:
        for instance in instances:
            if (instance / 'installation.json').exists():
                try:
                    settings = read_json(instance / 'installation.json')
                    logs = install.compose(instance, settings, 'logs', '--no-color', 'server')
                    (instance / 'server-observed.log').write_text(logs)
                except (OSError, RuntimeError) as error:
                    print('Could not preserve fixture logs: ' + str(error), file=sys.stderr)
        failures = fixture.cleanup(instances, resources)
        save_json(host / 'result.json', {'checks': checks, 'cleanup_failures': failures})
        print('Recovery fixture evidence: ' + str(host / 'result.json'), flush=True)
        if failures:
            raise RuntimeError('Fixture cleanup failed; inspect its private result')
    print(json.dumps({'passed': True, 'checks': checks}), flush=True)


if __name__ == '__main__':
    main()
